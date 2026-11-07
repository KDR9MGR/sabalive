import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart' hide Text;

import '../../../data/live_hearts_repository.dart';

/// The hearts of one live room, shared by everybody in it (owner, 2026-11-07: "like preview and count sync; sum of all users like and hearts should be seen by all").
///
/// - [count] is the sum of EVERYONE's hearts: the total the server last told us, plus this phone's taps that are not in it yet, so the number moves at once under the tapper's finger.
/// - A tap floats a heart at once ([bursts]) and is sent in a batch: at most [flushEvery] after the first tap of a run (not after every tap), 1..100 hearts a call.
/// - What others tap arrives over one Realtime watch of this live's row ([LiveHeartsApi.watch]): it sets the total and floats that many hearts (the layer thins a big batch). This phone's
///   own echo is recognised by `by == meId` and never floats a second time or counts twice.
/// - [api] null (a sample live that is not on the server) keeps everything on this phone.
/// - Everything fails open: no table, no channel, a failed send (the taps wait for the next batch).
class RoomHearts extends ChangeNotifier {
  RoomHearts({required this.streamId, this.api, this.meId, this.flushEvery = const Duration(seconds: 3)});

  final String streamId;
  final LiveHeartsApi? api;
  final String? meId;
  final Duration flushEvery;

  /// Taps waiting in one batch can not pile up beyond this (a phone offline for a long time).
  static const int maxPending = 2000;

  int _base = 0;
  int _pending = 0;
  int _inFlight = 0;
  Timer? _flushTimer;
  StreamSubscription<HeartsEvent>? _sub;
  bool _started = false;
  bool _disposed = false;

  final StreamController<int> _bursts = StreamController<int>.broadcast();

  /// How many hearts to float right now (1 for this person's tap, the batch size for somebody else's).
  Stream<int> get bursts => _bursts.stream;

  /// The sum of everybody's hearts, including this phone's taps that the server has not confirmed yet.
  int get count => _base + _pending + _inFlight;

  /// Reads the total and starts watching the live's row.
  Future<void> start() async {
    final server = api;
    if (_started || _disposed || server == null) return;
    _started = true;
    _sub = server.watch(streamId).listen(_onEvent, onError: (Object _) {});
    final total = await server.total(streamId);
    if (_disposed) return;
    if (total > _base) {
      _base = total;
      notifyListeners();
    }
  }

  /// This person tapped the heart.
  void tap() {
    if (_disposed) return;
    if (_pending < maxPending) _pending++;
    _bursts.add(1);
    notifyListeners();
    if (api != null) _flushTimer ??= Timer(flushEvery, () => unawaited(flush()));
  }

  /// Sends the taps waiting (also called when the room closes).
  Future<void> flush() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    final server = api;
    if (server == null || _pending == 0 || _inFlight > 0) {
      if (_pending > 0 && _inFlight > 0 && !_disposed) _flushTimer = Timer(const Duration(seconds: 1), () => unawaited(flush()));
      return;
    }
    final n = _pending > 100 ? 100 : _pending;
    _pending -= n;
    _inFlight = n;
    final total = await server.add(streamId, n);
    if (_disposed) return;
    if (total == null) {
      // it did not go: the taps wait for the next batch
      _pending += _inFlight;
      _inFlight = 0;
      _flushTimer ??= Timer(flushEvery * 2, () => unawaited(flush()));
    } else {
      _inFlight = 0;
      if (total > _base) _base = total;
      if (_pending > 0) _flushTimer ??= Timer(flushEvery, () => unawaited(flush()));
    }
    notifyListeners();
  }

  void _onEvent(HeartsEvent e) {
    if (_disposed) return;
    if (e.total > _base) _base = e.total;
    if (e.by != null && e.by == meId) {
      // my own batch coming back: it is in the total now, so it stops being "in flight" (and it floated when it was tapped)
      _inFlight = 0;
    } else if (e.count > 0) {
      _bursts.add(e.count);
    }
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _flushTimer?.cancel();
    unawaited(_sub?.cancel());
    final server = api;
    final waiting = _pending + _inFlight;
    if (server != null && waiting > 0) {
      // the room is closing: send what has not gone yet (best effort)
      unawaited(server.add(streamId, waiting > 100 ? 100 : waiting));
    }
    unawaited(_bursts.close());
    super.dispose();
  }
}

/// Floats the hearts of a [RoomHearts] up from the bottom of its box. Put it in a box (a [Positioned] of about 60 x 300 near the heart button); hearts start near the left of it.
/// One tap is one heart; a batch from other people is thinned to a handful ([perBurstCap]) spread over about a second, and no more than [maxOnScreen] float at once.
class RoomHeartsLayer extends StatefulWidget {
  const RoomHeartsLayer({super.key, required this.hearts, this.perBurstCap = 8, this.maxOnScreen = 40, this.spread = const Duration(milliseconds: 130)});

  final RoomHearts hearts;
  final int perBurstCap;
  final int maxOnScreen;
  final Duration spread;

  @override
  State<RoomHeartsLayer> createState() => _RoomHeartsLayerState();
}

class _RoomHeartsLayerState extends State<RoomHeartsLayer> {
  final List<Widget> _floating = [];
  final _rand = math.Random();
  StreamSubscription<int>? _sub;
  final List<Timer> _timers = [];

  @override
  void initState() {
    super.initState();
    _sub = widget.hearts.bursts.listen(_onBurst);
  }

  @override
  void didUpdateWidget(covariant RoomHeartsLayer old) {
    super.didUpdateWidget(old);
    if (old.hearts != widget.hearts) {
      _sub?.cancel();
      _sub = widget.hearts.bursts.listen(_onBurst);
    }
  }

  void _onBurst(int n) {
    final shown = n < widget.perBurstCap ? n : widget.perBurstCap;
    for (var i = 0; i < shown; i++) {
      if (i == 0) {
        _spawn();
      } else {
        late final Timer t;
        t = Timer(widget.spread * i, () {
          _timers.remove(t);
          _spawn();
        });
        _timers.add(t);
      }
    }
  }

  void _spawn() {
    if (!mounted || _floating.length >= widget.maxOnScreen) return;
    setState(() {
      _floating.add(RoomHeart(
        key: UniqueKey(),
        left: 8 + _rand.nextDouble() * 24,
        hue: _rand.nextDouble(),
        onDone: (k) {
          if (mounted) setState(() => _floating.removeWhere((h) => h.key == k));
        },
      ));
    });
  }

  @override
  void dispose() {
    for (final t in _timers) {
      t.cancel();
    }
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(child: Stack(clipBehavior: Clip.none, children: List<Widget>.of(_floating)));
}

/// One floating heart: rises about 300 px over 1.8 s, swaying, growing and fading out.
class RoomHeart extends StatefulWidget {
  const RoomHeart({required super.key, required this.left, required this.hue, required this.onDone});

  final double left;
  final double hue;
  final void Function(Key) onDone;

  @override
  State<RoomHeart> createState() => _RoomHeartState();
}

class _RoomHeartState extends State<RoomHeart> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800))..forward();

  @override
  void initState() {
    super.initState();
    _c.addStatusListener((s) {
      if (s == AnimationStatus.completed) widget.onDone(widget.key!);
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final v = _c.value;
        final sway = math.sin(v * math.pi * 3) * 14;
        return Positioned(
          left: widget.left + sway,
          bottom: v * 300,
          child: Opacity(
            opacity: (1 - v).clamp(0.0, 1.0),
            child: Transform.scale(
              scale: 0.6 + v * 0.8,
              child: Icon(Icons.favorite_rounded, color: HSVColor.fromAHSV(1, widget.hue * 360, 0.7, 1).toColor(), size: 26),
            ),
          ),
        );
      },
    );
  }
}
