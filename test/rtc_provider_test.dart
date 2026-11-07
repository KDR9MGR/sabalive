import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/config/app_environment.dart';
import 'package:sabalive/config/rtc_config.dart';
import 'package:sabalive/config/supabase_config.dart';
import 'package:sabalive/data/models.dart';
import 'package:sabalive/services/livekit_session.dart';

/// MS cloud (the hosted LiveKit server) next to Agora (owner, 2026-11-06): which provider a room uses, the stable uid every person gets on MS cloud, how its reports become the
/// Agora-shaped ones the live screens read, and the guards that keep a production build on Agora.
void main() {
  group('the provider of a room', () {
    test('what the database stores', () {
      expect(RtcProvider.agora.dbValue, 'agora');
      expect(RtcProvider.livekit.dbValue, 'livekit');
      expect(RtcProvider.fromDb('livekit'), RtcProvider.livekit);
      expect(RtcProvider.fromDb('agora'), RtcProvider.agora);
    });

    test('anything unknown, missing or empty is Agora: every older room and a database without the column', () {
      for (final v in [null, '', 'zoom', 'LIVEKIT', 5, true]) {
        expect(RtcProvider.fromDb(v), RtcProvider.agora, reason: '$v');
      }
    });

    test('a build starts Agora lives unless it is told otherwise (this test build is told nothing)', () {
      expect(RtcConfig.forNewLives, RtcProvider.agora);
      expect(RtcConfig.parse('livekit'), RtcProvider.livekit);
      expect(RtcConfig.parse('agora'), RtcProvider.agora);
      expect(RtcConfig.parse(null), RtcProvider.agora);
    });

    Map<String, dynamic> row([Map<String, dynamic> extra = const {}]) => {'id': 's1', 'title': 'T', 'mode': 'audio', ...extra};
    AppUser host() => AppUser(id: 'h', name: 'Host', username: '@h');

    test('a live row carries it; a row without the column is an Agora live', () {
      expect(LiveStream.fromRow(row({'rtc_provider': 'livekit'}), host()).rtcProvider, RtcProvider.livekit);
      expect(LiveStream.fromRow(row({'rtc_provider': 'livekit'}), host()).onLiveKit, isTrue);
      expect(LiveStream.fromRow(row({'rtc_provider': 'agora'}), host()).onLiveKit, isFalse);
      expect(LiveStream.fromRow(row(), host()).rtcProvider, RtcProvider.agora);
      expect(LiveStream.fromRow(row({'rtc_provider': null}), host()).onLiveKit, isFalse);
    });
  });

  group('the guards', () {
    test('a production build can never start MS cloud lives (the production database has no provider column yet)', () {
      expect(() => AppEnvironment.validate(environment: 'production', url: SupabaseConfig.productionUrl, newLivesProvider: RtcProvider.livekit), throwsStateError);
      expect(() => AppEnvironment.validate(environment: 'production', url: SupabaseConfig.productionUrl), returnsNormally);
      expect(() => AppEnvironment.validate(environment: 'production', url: SupabaseConfig.productionUrl, newLivesProvider: RtcProvider.agora), returnsNormally);
    });

    test('a staging build may use either, and still must not point at production', () {
      const staging = 'https://stagingref.supabase.co';
      expect(() => AppEnvironment.validate(environment: 'staging', url: staging, newLivesProvider: RtcProvider.livekit), returnsNormally);
      expect(() => AppEnvironment.validate(environment: 'staging', url: staging, newLivesProvider: RtcProvider.agora), returnsNormally);
      expect(() => AppEnvironment.validate(environment: 'staging', url: SupabaseConfig.productionUrl, newLivesProvider: RtcProvider.livekit), throwsStateError);
    });
  });

  group('the uid of a person on MS cloud', () {
    test('the same account id always gives the same number, whatever its case or the spaces around it', () {
      expect(liveKitUidOf('a1000000-0000-0000-0000-000000000001'), liveKitUidOf('A1000000-0000-0000-0000-000000000001'));
      expect(liveKitUidOf('a1000000-0000-0000-0000-000000000001'), liveKitUidOf('  a1000000-0000-0000-0000-000000000001 '));
    });

    test('REFERENCE VALUES: they are stored in the database (seat and host uid), so the way they are worked out must never change', () {
      expect(liveKitUidOf('a1000000-0000-0000-0000-000000000001'), 2009257832);
      expect(liveKitUidOf('b2000000-0000-0000-0000-000000000002'), 4254212883);
      expect(liveKitUidOf('00000000-0000-0000-0000-000000000000'), 3192360657);
      expect(liveKitUidOf('e1000000-0000-0000-0000-0000000000e1'), 1772584781);
    });

    test('it is a positive 32-bit number and never 0 (0 means "this phone" in a volume report)', () {
      for (final id in ['', 'x', 'a1000000-0000-0000-0000-000000000001', 'ffffffff-ffff-ffff-ffff-ffffffffffff', 'é', '😀']) {
        final uid = liveKitUidOf(id);
        expect(uid, greaterThan(0), reason: id);
        expect(uid, lessThanOrEqualTo(0xFFFFFFFF), reason: id);
      }
    });

    test('different people get different numbers (a room of 25 never collides in this sample)', () {
      final uids = {for (var i = 0; i < 2000; i++) liveKitUidOf('00000000-0000-4000-8000-${i.toRadixString(16).padLeft(12, '0')}')};
      expect(uids.length, 2000);
    });
  });

  group('who is talking, in Agora\'s shape', () {
    LiveKitSpeaker s(String id, {bool local = false, double level = 0.3}) => (identity: id, isLocal: local, level: level);

    test('this phone is uid 0, anybody else is their worked-out uid', () {
      final infos = volumeInfosFor([s('me', local: true), s('a1000000-0000-0000-0000-000000000001')]);
      expect(infos.length, 2);
      expect(infos[0].uid, 0);
      expect(infos[1].uid, 2009257832);
      expect(infos.every((i) => i.vad == 1), isTrue);
    });

    test('everyone LiveKit calls a speaker is above the screens\' thresholds (10 for others, 25 for this phone); a louder voice reports higher', () {
      final quiet = volumeInfosFor([s('x', level: 0.01)]).single.volume!;
      final loud = volumeInfosFor([s('x', level: 0.9)]).single.volume!;
      expect(quiet, greaterThan(25));
      expect(loud, greaterThan(quiet));
      expect(loud, lessThanOrEqualTo(255));
    });

    test('a nonsense level is kept in range, and nobody talking is an empty report', () {
      expect(volumeInfosFor([s('x', level: 7)]).single.volume, 255);
      expect(volumeInfosFor([s('x', level: -3)]).single.volume, greaterThan(25));
      expect(volumeInfosFor(const []), isEmpty);
    });
  });

  group('what a person is told', () {
    test('a sentence for each way the connection can end, and none names a vendor', () {
      const reasons = [null, 'unknown', 'duplicateIdentity', 'participantRemoved', 'roomDeleted', 'roomClosed', 'serverShutdown', 'migration', 'joinFailure', 'connectionTimeout', 'signalClose', 'disconnected', 'somethingNew'];
      for (final r in reasons) {
        final m = liveKitFailureMessage(r);
        expect(m, isNotEmpty);
        expect(m.toLowerCase(), isNot(contains('livekit')), reason: '$r');
        expect(m.toLowerCase(), isNot(contains('livecore')), reason: '$r');
        expect(m.toLowerCase(), isNot(contains('agora')), reason: '$r');
      }
      expect(liveKitFailureMessage('duplicateIdentity'), contains('another device'));
      expect(liveKitFailureMessage('participantRemoved'), contains('removed'));
      expect(liveKitFailureMessage('roomDeleted'), contains('ended'));
      expect(liveKitFailureMessage('somethingNew'), contains('lost'));
    });
  });

  group('the token the function sends', () {
    Map<String, dynamic> good() => {'token': 'abc.def.ghi', 'url': 'wss://x.example.cloud', 'room': 'r', 'identity': 'u1', 'expiresIn': 3600};

    test('a good answer is read', () {
      final t = LiveKitToken.fromJson(good());
      expect(t.token, 'abc.def.ghi');
      expect(t.url, 'wss://x.example.cloud');
      expect(t.identity, 'u1');
    });

    test('an answer with a piece missing, empty, or not on a secure address is refused', () {
      expect(() => LiveKitToken.fromJson(null), throwsException);
      expect(() => LiveKitToken.fromJson('text'), throwsException);
      for (final broken in [
        {...good()}..remove('token'),
        {...good()}..remove('url'),
        {...good()}..remove('identity'),
        {...good(), 'token': ''},
        {...good(), 'identity': ''},
        {...good(), 'url': 'http://insecure.example'},
        {...good(), 'url': 'ws://insecure.example'},
        {...good(), 'token': 5},
      ]) {
        expect(() => LiveKitToken.fromJson(broken), throwsException, reason: '$broken');
      }
    });
  });

  group('the live provider is a server switch (owner, 2026-11-07), Agora until it is turned on', () {
    test('a build that fixes the provider (staging) wins over the switch, either way', () {
      expect(RtcConfig.resolve(fixedByBuild: 'livekit', serverSwitchOn: false), RtcProvider.livekit);
      expect(RtcConfig.resolve(fixedByBuild: 'agora', serverSwitchOn: true), RtcProvider.agora);
    });

    test('a Play build (nothing fixed) follows the switch: on = MS cloud, off = Agora', () {
      expect(RtcConfig.resolve(fixedByBuild: '', serverSwitchOn: true), RtcProvider.livekit);
      expect(RtcConfig.resolve(fixedByBuild: '', serverSwitchOn: false), RtcProvider.agora);
    });

    test('this build fixes nothing and the switch has never been touched, so new lives are on Agora', () {
      expect(RtcConfig.fixedByBuild, isNull);
      expect(RtcConfig.serverSwitch, 'rtc_livekit_new_lives');
      expect(RtcConfig.forNewLives, RtcProvider.agora);
    });

    test('a production build may not fix the provider at build time, but a plain one passes (the switch is not a build-time thing)', () {
      expect(() => AppEnvironment.validate(newLivesProvider: RtcProvider.livekit), throwsStateError);
      AppEnvironment.validate(newLivesProvider: RtcConfig.fixedByBuild ?? RtcProvider.agora);
    });
  });
}
