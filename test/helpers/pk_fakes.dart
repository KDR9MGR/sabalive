import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/data/models.dart';
import 'package:sabalive/data/pk_battles_repository.dart';
import 'package:sabalive/state/pk_theme_store.dart';

/// The PK animations are bundled SVGA files and a layout / text test is not about them: it runs with them off, which is the plain
/// look the screens had before the animations existed (and the look a phone gets when the panel switches them off). Call it first
/// thing in `main()`: it registers a setUp / tearDown pair. A test of the animated look sets its own theme.
void usePlainPkLook() {
  setUp(() => PkThemeStore.instance.use(const PkTheme(animations: false)));
  tearDown(() => PkThemeStore.instance.use(const PkTheme()));
}

const pkMe = 'host-me';
const pkOther = 'host-other';
const pkMyStream = 'stream-me';
const pkOtherStream = 'stream-other';

PkBattleInfo pkRow({
  String id = 'b1',
  String status = 'invited',
  bool iAmA = true,
  int scoreA = 0,
  int scoreB = 0,
  DateTime? startedAt,
  DateTime? endsAt,
  String? winner,
  String? endReason,
  int seconds = 300,
  int seq = 0,
}) => PkBattleInfo(
  id: id,
  streamAId: iAmA ? pkMyStream : pkOtherStream,
  streamBId: iAmA ? pkOtherStream : pkMyStream,
  hostAId: iAmA ? pkMe : pkOther,
  hostBId: iAmA ? pkOther : pkMe,
  status: status,
  scoreA: scoreA,
  scoreB: scoreB,
  startedAt: startedAt,
  endsAt: endsAt,
  winner: winner,
  endReason: endReason,
  durationSeconds: seconds,
  kind: 'audio',
  source: 'invite',
  lastGiftSeq: seq,
);

class PkFakeWatch implements PkBattleWatch {
  bool closed = false;
  @override
  Future<void> close() async => closed = true;
}

/// A server in a box: records the calls and answers like the real one would.
class PkFakeApi implements PkBattlesApi {
  PkFakeApi(this.clock);
  final DateTime Function() clock;

  PkBattleInfo? current;
  Duration serverAhead = Duration.zero;
  final calls = <String>[];
  final randomAnswers = <PkBattleInfo?>[];
  Object? inviteError;
  Object? finalizeError;
  Object? giveUpError;
  int inviteSeconds = 300; // the length the invite carried: the server begins the battle with it
  void Function(PkBattleInfo)? onRow;
  final watch = PkFakeWatch();

  /// What the server sends over Realtime.
  void emit(PkBattleInfo row) => onRow?.call(row);

  PkBattleInfo liveRow({String id = 'b1', bool iAmA = true, int seconds = 300}) => pkRow(
    id: id,
    status: 'live',
    iAmA: iAmA,
    startedAt: clock().add(serverAhead),
    endsAt: clock().add(serverAhead).add(Duration(seconds: seconds)),
    seconds: seconds,
  );

  @override
  Future<PkBattleInfo?> currentBattleFor(String streamId) async {
    calls.add('current');
    return current;
  }

  /// What the server has stored for a battle id (a test sets it); the closing row of a finished battle is read through here.
  final byId = <String, PkBattleInfo>{};
  Object? readError;

  @override
  Future<PkBattleInfo?> battleById(String battleId) async {
    calls.add('read:$battleId');
    if (readError != null) throw readError!;
    return byId[battleId] ?? current;
  }

  @override
  Future<PkBattleInfo> inviteV2(String myStreamId, String targetStreamId, int durationSeconds) async {
    calls.add('invite:$targetStreamId:$durationSeconds');
    inviteSeconds = durationSeconds;
    if (inviteError != null) throw inviteError!;
    return pkRow(status: 'invited', seconds: durationSeconds);
  }

  List<PkCandidate> following = const [];

  @override
  Future<List<PkCandidate>> eligibleFollowing(String myStreamId) async => following;

  @override
  Future<PkBattleInfo?> randomJoin(String myStreamId) async {
    calls.add('random-join');
    return randomAnswers.isEmpty ? null : randomAnswers.removeAt(0);
  }

  @override
  Future<void> randomLeave(String myStreamId) async => calls.add('random-leave');

  @override
  Future<PkBattleInfo> respond(String battleId, bool accept) async {
    calls.add('respond:$accept');
    return pkRow(status: accept ? 'accepted' : 'cancelled', iAmA: false);
  }

  @override
  Future<void> cancel(String battleId) async => calls.add('cancel');

  @override
  Future<PkBattleInfo> beginV2(String battleId) async {
    calls.add('begin');
    return liveRow(id: battleId, seconds: inviteSeconds);
  }

  /// The host who gives up loses: in these rows I am side A, so side B wins.
  @override
  Future<PkBattleInfo> giveUp(String battleId) async {
    if (giveUpError != null) throw giveUpError!;
    calls.add('give-up');
    return pkRow(status: 'finished', scoreA: 90, scoreB: 10, winner: 'b', endReason: 'forfeit');
  }

  @override
  Future<PkBattleInfo> finalizeNow(String battleId) async {
    if (finalizeError != null) throw finalizeError!;
    calls.add('finalize');
    return pkRow(status: 'finished', scoreA: 30, scoreB: 10, winner: 'a');
  }

  @override
  Future<void> sendGift(String battleId, String side, Gift gift) async => calls.add('gift:$side');

  @override
  Future<void> setReady(String streamId, bool ready) async => calls.add('ready:$ready');

  @override
  Future<DateTime> serverNow() async => clock().add(serverAhead);

  @override
  Future<AppUser?> profile(String userId) async => AppUser(id: userId, name: 'Opponent', username: '@o');

  @override
  PkBattleWatch watchStream(String streamId, void Function(PkBattleInfo) onRow) {
    this.onRow = onRow;
    return watch;
  }
}

