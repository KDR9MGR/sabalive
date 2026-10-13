import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;
import 'package:sabalive/data/live_moderation_repository.dart';
import 'package:sabalive/state/room_moderation.dart';

class _FakeRepo extends Fake implements LiveModerationRepository {
  Set<String> admins = {};
  Set<String> off = {};
  final calls = <String>[];
  Object? failWith;

  @override
  Future<Set<String>> adminsOf(String hostId) async {
    if (failWith != null) throw failWith!;
    return admins;
  }

  @override
  Future<Set<String>> chatOffIn(String streamId) async => off;

  @override
  Future<void> kick(String streamId, String userId) async => calls.add('kick:$userId');

  @override
  Future<void> ban(String streamId, String userId) async => calls.add('ban:$userId');

  @override
  Future<void> setChatOff(String streamId, String userId, bool off) async => calls.add('chat:$userId:$off');

  @override
  Future<void> setAdmin(String userId, bool on) async => calls.add('admin:$userId:$on');
}

RoomModeration _room({required String me, _FakeRepo? repo, void Function(RemovalReason)? onRemoved}) => RoomModeration(
      streamId: 's1',
      hostId: 'host',
      myId: me,
      repo: repo ?? _FakeRepo(),
      listen: false,
      onRemoved: onRemoved,
    );

void main() {
  group('a server without room admins / text bans yet', () {
    test('is noticed, so the screens can leave those tools out', () async {
      final repo = _FakeRepo()
        ..failWith = const PostgrestException(message: 'Could not find the table public.live_room_admins', code: 'PGRST205');
      final m = _room(me: 'host', repo: repo);
      expect(m.serverHasModeration, isTrue, reason: 'assumed until the server says otherwise');
      await m.start();
      expect(m.serverHasModeration, isFalse);
      m.dispose();
    });

    test('a plain network failure does not hide the tools', () async {
      final repo = _FakeRepo()..failWith = Exception('offline');
      final m = _room(me: 'host', repo: repo);
      await m.start();
      expect(m.serverHasModeration, isTrue);
      m.dispose();
    });
  });

  group('who may moderate', () {
    test('the host may act on anyone but themselves', () async {
      final m = _room(me: 'host', repo: _FakeRepo()..admins = {'adm'});
      await m.start();
      expect(m.iAmHost, isTrue);
      expect(m.iAmModerator, isTrue);
      expect(m.canModerate('viewer'), isTrue);
      expect(m.canModerate('adm'), isTrue, reason: 'the host may act on an admin');
      expect(m.canModerate('host'), isFalse);
      m.dispose();
    });

    test('a room admin may act on viewers, but not on the host or another admin', () async {
      final m = _room(me: 'adm', repo: _FakeRepo()..admins = {'adm', 'adm2'});
      await m.start();
      expect(m.iAmAdmin, isTrue);
      expect(m.iAmModerator, isTrue);
      expect(m.canModerate('viewer'), isTrue);
      expect(m.canModerate('host'), isFalse);
      expect(m.canModerate('adm2'), isFalse);
      expect(m.canModerate('adm'), isFalse, reason: 'not themselves');
      m.dispose();
    });

    test('an ordinary viewer may not moderate anyone', () async {
      final m = _room(me: 'viewer', repo: _FakeRepo()..admins = {'adm'});
      await m.start();
      expect(m.iAmModerator, isFalse);
      expect(m.canModerate('someone'), isFalse);
      m.dispose();
    });

    test('someone who is not signed in has no tools', () {
      final m = RoomModeration(streamId: 's', hostId: 'h', myId: null, repo: _FakeRepo(), listen: false);
      expect(m.iAmModerator, isFalse);
      expect(m.chatOff, isFalse);
      m.dispose();
    });
  });

  group('what changes in the room', () {
    test('an admin added or removed while the live runs updates the list', () {
      final m = _room(me: 'viewer');
      var heard = 0;
      m.addListener(() => heard++);
      m.applyAdmin('a1', true);
      expect(m.isAdmin('a1'), isTrue);
      m.applyAdmin('a1', true); // same again: nothing to announce
      m.applyAdmin('a1', false);
      expect(m.isAdmin('a1'), isFalse);
      expect(heard, 2);
      m.dispose();
    });

    test('my own chat being turned off, and back on', () {
      final m = _room(me: 'viewer');
      expect(m.chatOff, isFalse);
      m.applyChatOff('viewer', true);
      expect(m.chatOff, isTrue);
      expect(m.isChatOff('viewer'), isTrue);
      m.applyChatOff('viewer', false);
      expect(m.chatOff, isFalse);
      m.dispose();
    });

    test("someone else's chat being off is not mine", () {
      final m = _room(me: 'viewer');
      m.applyChatOff('other', true);
      expect(m.chatOff, isFalse);
      expect(m.isChatOff('other'), isTrue);
      m.dispose();
    });

    test('being kicked or banned is reported once, however many signals arrive', () {
      final reasons = <RemovalReason>[];
      final m = _room(me: 'viewer', onRemoved: reasons.add);
      m.removed(RemovalReason.kicked);
      m.removed(RemovalReason.banned);
      expect(reasons, [RemovalReason.kicked]);
      m.dispose();
    });

    test('nothing happens after the screen is gone', () {
      final reasons = <RemovalReason>[];
      final m = _room(me: 'viewer', onRemoved: reasons.add);
      m.dispose();
      m.removed(RemovalReason.banned);
      m.applyAdmin('x', true);
      expect(reasons, isEmpty);
      expect(m.admins, isEmpty);
    });

    test('the live still works when the moderation lists cannot be read', () async {
      final m = _room(me: 'viewer', repo: _FakeRepo()..failWith = Exception('offline'));
      await m.start();
      expect(m.admins, isEmpty);
      expect(m.iAmModerator, isFalse);
      m.dispose();
    });

    test('the chat that was already off when the screen opened is known', () async {
      final m = _room(me: 'viewer', repo: _FakeRepo()..off = {'viewer'});
      await m.start();
      expect(m.chatOff, isTrue);
      m.dispose();
    });
  });

  group('actions', () {
    test('kick, ban, text ban and admin go to the server, and the screen is updated at once', () async {
      final repo = _FakeRepo();
      final m = _room(me: 'host', repo: repo);
      await m.kick('a');
      await m.ban('b');
      await m.setChatOff('c', true);
      await m.setAdmin('d', true);
      expect(repo.calls, ['kick:a', 'ban:b', 'chat:c:true', 'admin:d:true']);
      expect(m.isChatOff('c'), isTrue);
      expect(m.isAdmin('d'), isTrue);
      await m.setChatOff('c', false);
      await m.setAdmin('d', false);
      expect(m.isChatOff('c'), isFalse);
      expect(m.isAdmin('d'), isFalse);
      m.dispose();
    });

    test('a refused action leaves the screen as it was', () async {
      final repo = _FakeRepo();
      final m = _room(me: 'host', repo: repo);
      final failing = _FailingRepo();
      final m2 = RoomModeration(streamId: 's', hostId: 'host', myId: 'host', repo: failing, listen: false);
      await expectLater(m2.setChatOff('c', true), throwsException);
      expect(m2.isChatOff('c'), isFalse);
      m.dispose();
      m2.dispose();
    });
  });
}

class _FailingRepo extends _FakeRepo {
  @override
  Future<void> setChatOff(String streamId, String userId, bool off) async => throw Exception('Only the host');
}
