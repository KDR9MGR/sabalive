import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../core/utils/errors.dart';
import '../data/models.dart';
import '../data/pk_battles_repository.dart';

/// Where a live stands in a PK battle, as the screen needs to draw it.
enum PkPhase {
  /// No battle. The host can invite someone or search for a random opponent.
  idle,

  /// The host asked for a random opponent and is waiting to be paired.
  searching,

  /// I invited someone and wait for their answer.
  inviting,

  /// Someone invited me: Accept or Decline.
  incoming,

  /// Both agreed (or a random pair was made): the 3 s countdown, then the battle begins.
  countdown,

  /// The battle runs: scores, a timer, the shared channel.
  live,

  /// The battle is over: [PkBattleController.result] says who won.
  finished,

  /// Declined, cancelled, timed out or never started: [PkBattleController.message] says why.
  cancelled,
}

enum PkOutcome { win, lose, draw }

/// How a finished battle ended, from MY side.
class PkResult {
  const PkResult({required this.outcome, required this.mine, required this.theirs, required this.forfeit});

  final PkOutcome outcome;
  final int mine;
  final int theirs;

  /// A host left or dropped: the host who stayed wins whatever the score was.
  final bool forfeit;
}

/// Runs one live's PK battle on the client: follows the server's `pk_battles` row (the single source of truth: this class never
/// decides a score, a winner or a length), turns it into a [PkPhase] for the screen, drives the 3 s countdown and the timer, and
/// tells the screen when to move to the shared Agora channel and back.
///
/// One per live room, owned by the host or the viewer screen (no provider needed). Written to be repeatable and out-of-order safe:
/// Realtime can deliver the same row twice, or an older one after a newer one, so a row only counts if its state is not behind
/// what is already known for that battle.
class PkBattleController extends ChangeNotifier {
  PkBattleController({
    required this.api,
    required this.streamId,
    required this.myHostId,
    this.onChannel,
    this.countdown = const Duration(seconds: 3),
    this.searchEvery = const Duration(seconds: 5),
    this.searchTimeout = const Duration(seconds: 60),
    this.recheckEvery = const Duration(seconds: 60),
    this.finalBellWait = const Duration(seconds: 4),
    Duration? jitter,
    DateTime Function()? clock,
  }) : _clock = clock ?? (() => DateTime.now().toUtc()),
       _jitter = jitter ?? Duration(milliseconds: math.Random().nextInt(15000));

  final PkBattlesApi api;

  /// The live this screen is in (a host's own, or the one a viewer watches) and the host who owns it.
  final String streamId;
  final String myHostId;

  /// Called with the shared channel when the battle goes live and with null when it ends, so the screen can move everybody's audio.
  final void Function(String? channel)? onChannel;
  final Duration countdown;
  final Duration searchEvery;
  final Duration searchTimeout;

  /// Realtime tells every phone about every change, but a dropped connection can lose one. So a phone that is live asks the server
  /// for the battle itself: every [recheckEvery] (plus its own random spread, so a room of hundreds does not ask in the same second),
  /// and when [finalBellWait] has passed after the clock reached zero with no closing row (without this a viewer who missed it would
  /// sit at 00:00 for ever).
  final Duration recheckEvery;
  final Duration finalBellWait;
  final Duration _jitter;
  final DateTime Function() _clock;
  DateTime _lastRead = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  DateTime? _lateRead;

  PkPhase _phase = PkPhase.idle;
  PkBattleInfo? _battle;
  AppUser? _opponent;
  PkResult? _result;
  String? _message;
  bool _busy = false;

  /// Whole seconds left in a live battle, counted against the SERVER's clock. Changes once a second, only while live.
  final ValueNotifier<int> secondsLeft = ValueNotifier<int>(0);

  PkBattleWatch? _watch;
  Timer? _tick;
  Timer? _countdownTimer;
  Timer? _searchTimer;
  DateTime? _searchStarted;
  Duration _skew = Duration.zero; // server time minus phone time
  bool _inSharedChannel = false;
  bool _finalizeSent = false;
  bool _disposed = false;
  final Set<String> _acknowledged = {}; // finished / cancelled battles the screen has dismissed

  PkPhase get phase => _phase;
  PkBattleInfo? get battle => _battle;

  /// The other host (null until the profile is loaded).
  AppUser? get opponent => _opponent;
  PkResult? get result => _result;

  /// Why the last battle was cancelled, or what went wrong with the last action. Cleared by the next action.
  String? get message => _message;

  /// An invite, an answer or a search request is in flight.
  bool get busy => _busy;

  /// 'a' or 'b': the side of this live in the current battle.
  String? get mySide => _battle?.sideFor(streamId);

  /// The other live of the current battle (null without one).
  String? get opponentStreamId {
    final b = _battle;
    if (b == null) return null;
    return b.streamAId == streamId ? b.streamBId : b.streamAId;
  }
  bool get amHost => _battle != null && (_battle!.hostAId == myHostId || _battle!.hostBId == myHostId);
  int get scoreMine => _battle == null ? 0 : (mySide == 'b' ? _battle!.scoreB : _battle!.scoreA);
  int get scoreTheirs => _battle == null ? 0 : (mySide == 'b' ? _battle!.scoreA : _battle!.scoreB);

  /// Is a battle going on that blocks other actions (not idle, not over)?
  bool get inBattle => const {PkPhase.inviting, PkPhase.incoming, PkPhase.countdown, PkPhase.live}.contains(_phase);

  /// The two rooms are face to face: the 3-2-1 or the battle itself (the arena is on screen, not just a "waiting" strip).
  bool get fighting => _phase == PkPhase.countdown || _phase == PkPhase.live;

  DateTime _serverNow() => _clock().add(_skew);

  // ------------------------------------------------------------------------------------------------------ start / stop
  /// Learns the server's time, picks up a battle that already exists for this live (a viewer joining mid-battle, a host coming
  /// back) and starts listening for changes.
  Future<void> start() async {
    await _syncClock(fallbackToPhone: true);
    if (_disposed) return;
    _watch = api.watchStream(streamId, _onRow);
    try {
      final current = await api.currentBattleFor(streamId);
      if (current != null && !_disposed) _apply(current);
    } catch (_) {
      // Realtime will still deliver changes; the first one fills the state in
    }
  }

  Future<void> _syncClock({bool fallbackToPhone = false}) async {
    try {
      final before = _clock();
      final server = await api.serverNow();
      final after = _clock();
      // half the round trip is the time the answer spent on the way
      _skew = server.difference(before.add(after.difference(before) ~/ 2));
    } catch (_) {
      if (fallbackToPhone) _skew = Duration.zero; // the phone's clock is the best guess left
    }
  }

  /// Asks the server for this battle (or, with none yet, for the one this live is in) and applies it: the same rows Realtime would
  /// have sent, safe to apply twice or late. For a phone that may have missed one: back from the background ([resync] also measures
  /// the server's clock again), after a reconnect, and the safety reads described at [recheckEvery].
  Future<void> refresh({bool resync = false}) async {
    if (_disposed) return;
    _lastRead = _clock();
    try {
      if (resync) await _syncClock();
      final known = _battle;
      final row = known == null ? await api.currentBattleFor(streamId) : await api.battleById(known.id);
      if (row != null && !_disposed) _apply(row);
    } catch (_) {
      // offline: Realtime or the next read will fill it in
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _tick?.cancel();
    _countdownTimer?.cancel();
    _searchTimer?.cancel();
    if (_phase == PkPhase.searching) unawaited(api.randomLeave(streamId).catchError((_) {}));
    unawaited(_watch?.close());
    secondsLeft.dispose();
    super.dispose();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  // ---------------------------------------------------------------------------------------------------------- actions
  /// Invite a host from the Following list. [durationSeconds] must be one of the lengths the server offers.
  Future<void> invite(PkCandidate target, int durationSeconds) async {
    if (_busy || inBattle) return;
    await _run(() async {
      final row = await api.inviteV2(streamId, target.streamId, durationSeconds);
      _apply(row);
    });
  }

  /// Search for a random opponent: asks the server every [searchEvery] until paired, [searchTimeout] passes or [stopSearch].
  Future<void> searchRandom() async {
    if (_busy || inBattle || _phase == PkPhase.searching) return;
    _message = null;
    _phase = PkPhase.searching;
    _searchStarted = _clock();
    _notify();
    await _searchOnce();
    if (_phase == PkPhase.searching) {
      _searchTimer = Timer.periodic(searchEvery, (_) => _searchOnce());
    }
  }

  Future<void> _searchOnce() async {
    if (_phase != PkPhase.searching) return;
    if (_clock().difference(_searchStarted!) >= searchTimeout) {
      await stopSearch(message: 'No opponent found. Try again.');
      return;
    }
    try {
      final row = await api.randomJoin(streamId);
      if (row != null) {
        _searchTimer?.cancel();
        _apply(row);
      }
    } catch (e) {
      await stopSearch(message: _plain(e));
    }
  }

  Future<void> stopSearch({String? message}) async {
    if (_phase != PkPhase.searching) return;
    _searchTimer?.cancel();
    _phase = PkPhase.idle;
    _message = message;
    _notify();
    try {
      await api.randomLeave(streamId);
    } catch (_) {
      // the server drops an entry nobody refreshes after a few seconds anyway
    }
  }

  /// Accept or decline the invite shown in [PkPhase.incoming].
  Future<void> respond(bool accept) async {
    final b = _battle;
    if (_busy || b == null || _phase != PkPhase.incoming) return;
    await _run(() async => _apply(await api.respond(b.id, accept)));
  }

  /// Withdraw my invite (or leave a battle that has not begun).
  Future<void> cancel() async {
    final b = _battle;
    if (_busy || b == null || !(_phase == PkPhase.inviting || _phase == PkPhase.countdown)) return;
    await _run(() async {
      await api.cancel(b.id);
      _cancelled(b, 'The PK was cancelled.');
    });
  }

  /// A host ends a live battle by giving up: they lose and the other host wins (reason 'forfeit', so both result screens explain it).
  /// Only while it is live and only for a host of the battle. Needs the server's `pk_give_up_v2`: on a server without it the battle
  /// goes on and [message] says so.
  Future<void> giveUp() async {
    final b = _battle;
    if (_busy || b == null || _phase != PkPhase.live || !amHost) return;
    await _run(() async {
      try {
        final row = await api.giveUp(b.id);
        _finalizeSent = true;
        _apply(row);
      } catch (e) {
        if (isMissingOnServer(e)) {
          _message = friendlyError(e);
        } else {
          rethrow;
        }
      }
    });
  }

  /// Gift to one side of the battle ('a' or 'b'); the server adds the coins to that side's score.
  Future<void> gift(String side, Gift gift) async {
    final b = _battle;
    if (b == null || _phase != PkPhase.live) return;
    await api.sendGift(b.id, side, gift);
  }

  /// Clears a finished / cancelled battle so the host can start another.
  void acknowledge() {
    if (_phase == PkPhase.finished || _phase == PkPhase.cancelled) {
      if (_battle != null) _acknowledged.add(_battle!.id);
      _phase = PkPhase.idle;
      _battle = null;
      _opponent = null;
      _result = null;
      _message = null;
      _finalizeSent = false;
      _notify();
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    _busy = true;
    _message = null;
    _notify();
    try {
      await action();
    } catch (e) {
      _message = _plain(e);
    } finally {
      _busy = false;
      _notify();
    }
  }

  String _plain(Object e) {
    final text = e.toString();
    // PostgrestException: "message: ..." keeps the server's own sentence (they are written to be shown)
    final m = RegExp(r'message: ([^,}]+)').firstMatch(text);
    return (m?.group(1) ?? text).trim();
  }

  // ------------------------------------------------------------------------------------------------------ server rows
  void _onRow(PkBattleInfo row) {
    if (!_disposed) _apply(row);
  }

  static int _rank(String status) => switch (status) {
    'invited' => 1,
    'accepted' => 2,
    'live' => 3,
    'finished' || 'cancelled' => 4,
    _ => 0,
  };

  /// Takes a row from the server (an answer to my own call, or Realtime). Safe to call twice with the same row, or with an older
  /// row after a newer one.
  void _apply(PkBattleInfo b) {
    _lastRead = _clock();
    if (_acknowledged.contains(b.id)) return;
    final current = _battle;
    if (current != null && current.id == b.id) {
      if (_rank(b.status) < _rank(current.status)) return; // behind what we know
      if (_rank(b.status) == 4 && _rank(current.status) == 4) return; // already over
      if (_rank(b.status) == _rank(current.status) &&
          b.scoreA == current.scoreA && b.scoreB == current.scoreB && b.lastGiftSeq == current.lastGiftSeq) {
        return; // the same row again
      }
    } else if (current != null && _rank(current.status) < 4 && _phase != PkPhase.searching) {
      return; // a different battle while one is going on: the server never does this; ignore it
    }

    final previousStatus = current?.id == b.id ? current?.status : null;
    final phaseBefore = _phase;
    _battle = b;
    _loadOpponent(b);

    switch (b.status) {
      case 'invited':
        _searchTimer?.cancel();
        // only the invited host (side B) is asked; the inviter, and everybody who just watches, sees "waiting"
        _phase = b.hostBId == myHostId ? PkPhase.incoming : PkPhase.inviting;
      case 'accepted':
        _searchTimer?.cancel();
        if (_phase != PkPhase.countdown) {
          _phase = PkPhase.countdown;
          _countdownTimer?.cancel();
          _countdownTimer = Timer(countdown, () => _begin(b.id));
        }
      case 'live':
        _searchTimer?.cancel();
        _countdownTimer?.cancel();
        final wasLive = _phase == PkPhase.live;
        _phase = PkPhase.live;
        if (!wasLive) {
          _finalizeSent = false;
          _startTick();
          _switchChannel(b.agoraChannel);
        }
        _updateSeconds();
      case 'finished':
        if (previousStatus != 'finished') _finish(b);
      case 'cancelled':
        if (previousStatus != 'cancelled') _cancelled(b, _cancelMessage(phaseBefore));
    }
    _notify();
  }

  String _cancelMessage(PkPhase before) => switch (before) {
    PkPhase.inviting => 'The invite was declined or nobody answered.',
    PkPhase.incoming => 'The invite is no longer active.',
    _ => 'The PK was cancelled.',
  };

  Future<void> _begin(String battleId) async {
    if (_disposed || _battle?.id != battleId || _phase != PkPhase.countdown) return;
    try {
      _apply(await api.beginV2(battleId)); // both phones call it; the second call is a no-op on the server
    } catch (e) {
      // the other host may have begun it already (its row is on the way), or a live ended: the server row decides
      if (_phase == PkPhase.countdown) {
        try {
          final current = await api.currentBattleFor(streamId);
          if (current != null) _apply(current);
        } catch (_) {}
      }
    }
  }

  void _startTick() {
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _updateSeconds());
  }

  void _updateSeconds() {
    final b = _battle;
    if (b == null || b.endsAt == null || _phase != PkPhase.live) return;
    final left = b.endsAt!.difference(_serverNow()).inSeconds;
    secondsLeft.value = left < 0 ? 0 : left;
    final now = _clock();
    if (left <= -(finalBellWait + Duration(milliseconds: _jitter.inMilliseconds % 2500)).inSeconds) {
      // past the final bell and the closing row has not come: ask for it, then again every few seconds
      if (_lateRead == null || now.difference(_lateRead!) >= const Duration(seconds: 8)) {
        _lateRead = now;
        unawaited(refresh());
      }
    } else if (now.difference(_lastRead) >= recheckEvery + _jitter) {
      unawaited(refresh());
    }
    // the time is up: a host asks the server to close it at once (the server also does it within a minute, whoever asks)
    if (left <= 0 && amHost && !_finalizeSent) {
      _finalizeSent = true;
      unawaited(() async {
        try {
          _apply(await api.finalizeNow(b.id));
        } catch (_) {
          // the other host or the server's sweep got there first
        }
      }());
    }
  }

  void _finish(PkBattleInfo b) {
    _tick?.cancel();
    _countdownTimer?.cancel();
    final side = b.sideFor(streamId);
    final outcome = b.winner == 'draw' || b.winner == null
        ? PkOutcome.draw
        : (b.winner == side ? PkOutcome.win : PkOutcome.lose);
    _result = PkResult(
      outcome: outcome,
      mine: side == 'b' ? b.scoreB : b.scoreA,
      theirs: side == 'b' ? b.scoreA : b.scoreB,
      forfeit: b.endReason == 'forfeit',
    );
    _phase = PkPhase.finished;
    secondsLeft.value = 0;
    _switchChannel(null);
  }

  void _cancelled(PkBattleInfo b, String message) {
    _tick?.cancel();
    _countdownTimer?.cancel();
    _phase = PkPhase.cancelled;
    _message = message;
    secondsLeft.value = 0;
    _switchChannel(null);
  }

  void _switchChannel(String? channel) {
    if (channel != null) {
      _inSharedChannel = true;
      onChannel?.call(channel);
    } else if (_inSharedChannel) {
      _inSharedChannel = false;
      onChannel?.call(null);
    }
  }

  /// The host of the OTHER live of the battle. Decided from which side THIS live is on, never from [myHostId]: a viewer's id is neither
  /// host's, so comparing with it made a viewer of side A "see" host A as the opponent (the same person on both halves).
  String _otherHostId(PkBattleInfo b) => switch (b.sideFor(streamId)) {
    'a' => b.hostBId,
    'b' => b.hostAId,
    _ => b.hostAId == myHostId ? b.hostBId : b.hostAId,
  };

  Future<void> _loadOpponent(PkBattleInfo b) async {
    final otherId = _otherHostId(b);
    if (_opponent?.id == otherId) return;
    try {
      final profile = await api.profile(otherId);
      if (profile != null && !_disposed && _battle?.id == b.id) {
        _opponent = profile;
        _notify();
      }
    } catch (_) {
      // the avatar and name are cosmetic
    }
  }
}
