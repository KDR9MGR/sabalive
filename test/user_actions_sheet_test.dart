import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/data/live_moderation_repository.dart';
import 'package:sabalive/data/models.dart';
import 'package:sabalive/features/live/widgets/user_actions_sheet.dart';
import 'package:sabalive/state/room_moderation.dart';

class _FakeRepo extends Fake implements LiveModerationRepository {
  Set<String> admins = {};
  final calls = <String>[];

  @override
  Future<Set<String>> adminsOf(String hostId) async => admins;
  @override
  Future<Set<String>> chatOffIn(String streamId) async => {};
  @override
  Future<void> kick(String streamId, String userId) async => calls.add('kick:$userId');
  @override
  Future<void> ban(String streamId, String userId) async => calls.add('ban:$userId');
  @override
  Future<void> setChatOff(String streamId, String userId, bool off) async => calls.add('chat:$userId:$off');
  @override
  Future<void> setAdmin(String userId, bool on) async => calls.add('admin:$userId:$on');
  @override
  Future<void> muteSeat(String streamId, int seat, bool muted) async => calls.add('mute:$seat:$muted');
  @override
  Future<void> removeFromSeat(String streamId, int seat) async => calls.add('unseat:$seat');
}

AppUser _u(String id, String name) => AppUser(id: id, name: name, username: '@$id');

Future<RoomModeration> _room(String me, _FakeRepo repo, {Set<String> admins = const {}}) async {
  repo.admins = {...admins};
  final m = RoomModeration(streamId: 's1', hostId: 'host', myId: me, repo: repo, listen: false);
  await m.start();
  return m;
}

Widget _app(Future<void> Function(BuildContext) open) => MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(child: ElevatedButton(onPressed: () => open(context), child: const Text('open'))),
        ),
      ),
    );

Future<void> _open(WidgetTester t, RoomModeration m, AppUser target, {int? seat, bool admins = false}) async {
  await t.pumpWidget(_app((c) => showUserActionsSheet(
        c,
        user: target,
        streamId: 's1',
        moderation: m,
        seat: seat,
        allowAdmins: admins,
      )));
  await t.tap(find.text('open'));
  await t.pumpAndSettle();
}

void main() {
  testWidgets('an ordinary viewer sees only profile and report', (t) async {
    final m = await _room('viewer', _FakeRepo());
    await _open(t, m, _u('other', 'Riya'));
    expect(find.text('View profile'), findsOneWidget);
    expect(find.text('Report'), findsOneWidget);
    expect(find.text('Kick from live'), findsNothing);
    expect(find.text('Ban from this live'), findsNothing);
    expect(find.text('Ban text'), findsNothing);
    m.dispose();
  });

  testWidgets('nobody can report themselves', (t) async {
    final m = await _room('viewer', _FakeRepo());
    await _open(t, m, _u('viewer', 'Me'));
    expect(find.text('Report'), findsNothing);
    m.dispose();
  });

  testWidgets('the host sees kick, ban and ban text, and in an audio room can make an admin', (t) async {
    final m = await _room('host', _FakeRepo());
    await _open(t, m, _u('other', 'Riya'), admins: true);
    expect(find.text('Kick from live'), findsOneWidget);
    expect(find.text('Ban from this live'), findsOneWidget);
    expect(find.text('Ban text'), findsOneWidget);
    expect(find.text('Make room admin'), findsOneWidget);
    m.dispose();
  });

  testWidgets('a video live offers the host no admin option', (t) async {
    final m = await _room('host', _FakeRepo());
    await _open(t, m, _u('other', 'Riya'));
    expect(find.text('Make room admin'), findsNothing);
    m.dispose();
  });

  testWidgets('a room admin has the tools on a viewer but not on the host or another admin, and cannot make admins', (t) async {
    final repo = _FakeRepo();
    final m = await _room('adm', repo, admins: {'adm', 'adm2'});
    await _open(t, m, _u('other', 'Riya'), admins: true);
    expect(find.text('Kick from live'), findsOneWidget);
    expect(find.text('Make room admin'), findsNothing);
    await t.tapAt(const Offset(5, 5)); // close
    await t.pumpAndSettle();
    await _open(t, m, _u('adm2', 'Other admin'), admins: true);
    expect(find.text('Kick from live'), findsNothing);
    expect(find.text('Room admin'), findsOneWidget, reason: 'shown as an admin');
    m.dispose();
  });

  testWidgets('kicking asks first, then does it', (t) async {
    final repo = _FakeRepo();
    final m = await _room('host', repo);
    await _open(t, m, _u('other', 'Riya'));
    await t.tap(find.text('Kick from live'));
    await t.pumpAndSettle();
    expect(find.text('Kick Riya?'), findsOneWidget);
    expect(repo.calls, isEmpty, reason: 'nothing yet');
    await t.tap(find.text('Kick'));
    await t.pumpAndSettle();
    expect(repo.calls, ['kick:other']);
    m.dispose();
  });

  testWidgets('cancelling a ban does nothing', (t) async {
    final repo = _FakeRepo();
    final m = await _room('host', repo);
    await _open(t, m, _u('other', 'Riya'));
    await t.tap(find.text('Ban from this live'));
    await t.pumpAndSettle();
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    expect(repo.calls, isEmpty);
    m.dispose();
  });

  testWidgets('ban text, then the sheet offers to allow text again', (t) async {
    final repo = _FakeRepo();
    final m = await _room('host', repo);
    await _open(t, m, _u('other', 'Riya'));
    await t.tap(find.text('Ban text'));
    await t.pumpAndSettle();
    expect(repo.calls, ['chat:other:true']);
    await _open(t, m, _u('other', 'Riya'));
    expect(find.text('Allow text'), findsOneWidget);
    expect(find.text('Ban text'), findsNothing);
    m.dispose();
  });

  testWidgets('on a seat, a moderator can also mute the microphone or take them off the seat', (t) async {
    final repo = _FakeRepo();
    final m = await _room('host', repo);
    await _open(t, m, _u('other', 'Riya'), seat: 3);
    expect(find.text('Mute microphone'), findsOneWidget);
    await t.tap(find.text('Remove from seat'));
    await t.pumpAndSettle();
    expect(repo.calls, ['unseat:3']);
    m.dispose();
  });

  testWidgets('making a room admin, and taking it away', (t) async {
    final repo = _FakeRepo();
    final m = await _room('host', repo);
    await _open(t, m, _u('other', 'Riya'), admins: true);
    await t.tap(find.text('Make room admin'));
    await t.pumpAndSettle();
    expect(repo.calls, ['admin:other:true']);
    await _open(t, m, _u('other', 'Riya'), admins: true);
    expect(find.text('Remove room admin'), findsOneWidget);
    m.dispose();
  });
}
