import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/services/local_music_service.dart';

const _connection = RtcConnection(channelId: 'room-1', localUid: 7);

void main() {
  late _FakeEngine engine;
  late LocalMusicController music;
  var disposed = false;

  setUp(() {
    disposed = false;
    engine = _FakeEngine();
    music = LocalMusicController(engine);
    music.queue.add(MusicTrack('Song A', '/music/a.mp3'));
    music.queue.add(MusicTrack('Song B', '/music/b.mp3'));
  });

  tearDown(() {
    if (!disposed) music.dispose();
  });

  /// A song is playing: the first one was started and Agora said so.
  Future<void> playFirst() async {
    await music.next(); // not at the start yet: index is -1, so this starts song 0
    engine.say(AudioMixingStateType.audioMixingStatePlaying, AudioMixingReasonType.audioMixingReasonOk);
  }

  test('a song starts into the channel for everyone, at the chosen volume', () async {
    await playFirst();
    expect(engine.started, ['/music/a.mp3']);
    expect(engine.loopbacks, [false]);
    expect(engine.volumes, [60]);
    expect(music.playing, isTrue);
  });

  test('a song goes on after a PK battle moves the live to another channel and back', () async {
    await playFirst();

    engine.leave();
    engine.join();
    await pumpEventQueue();
    expect(engine.started, ['/music/a.mp3', '/music/a.mp3'], reason: 'the same song, started again in the new channel');

    engine.say(AudioMixingStateType.audioMixingStatePlaying, AudioMixingReasonType.audioMixingReasonOk);
    engine.leave();
    engine.join();
    await pumpEventQueue();
    expect(engine.started, hasLength(3), reason: 'and again when the battle ends');
  });

  test('the song that was playing is the one restarted, not the first', () async {
    await playFirst();
    await music.next();
    engine.say(AudioMixingStateType.audioMixingStatePlaying, AudioMixingReasonType.audioMixingReasonOk);

    engine.leave();
    engine.join();
    await pumpEventQueue();
    expect(engine.started.last, '/music/b.mp3');
  });

  test('only-me playback stays only-me after the move', () async {
    music.onlyMe = true;
    await playFirst();
    engine.leave();
    engine.join();
    await pumpEventQueue();
    expect(engine.loopbacks, [true, true]);
  });

  test('nothing starts when no song was playing', () async {
    engine.leave();
    engine.join();
    await pumpEventQueue();
    expect(engine.started, isEmpty);
  });

  test('nothing starts after the host stopped the music', () async {
    await playFirst();
    await music.stop();
    engine.leave();
    engine.join();
    await pumpEventQueue();
    expect(engine.started, ['/music/a.mp3']);
  });

  test('stopping between the leave and the join cancels the restart', () async {
    await playFirst();
    engine.leave();
    await music.stop();
    engine.join();
    await pumpEventQueue();
    expect(engine.started, ['/music/a.mp3']);
  });

  test('a join without a leave before it (the first join) starts nothing', () async {
    await playFirst();
    engine.join();
    await pumpEventQueue();
    expect(engine.started, ['/music/a.mp3']);
  });

  test('after the screen is gone a channel change does nothing', () async {
    await playFirst();
    music.dispose();
    disposed = true;
    engine.leave();
    engine.join();
    await pumpEventQueue();
    expect(engine.started, ['/music/a.mp3']);
    expect(engine.handlers, isEmpty, reason: 'the controller unregisters its listener');
  });

  test('the next song follows when one finishes', () async {
    await playFirst();
    engine.say(AudioMixingStateType.audioMixingStateStopped, AudioMixingReasonType.audioMixingReasonAllLoopsCompleted);
    await pumpEventQueue();
    expect(engine.started, ['/music/a.mp3', '/music/b.mp3']);
  });
}

/// Records what the music controller asks of Agora and lets a test play the part of Agora's callbacks.
class _FakeEngine implements RtcEngine {
  final List<RtcEngineEventHandler> handlers = [];
  final List<String> started = [];
  final List<bool> loopbacks = [];
  final List<int> volumes = [];

  void say(AudioMixingStateType state, AudioMixingReasonType reason) {
    for (final h in List.of(handlers)) {
      h.onAudioMixingStateChanged?.call(state, reason);
    }
  }

  void leave() {
    for (final h in List.of(handlers)) {
      h.onLeaveChannel?.call(_connection, const RtcStats());
    }
  }

  void join() {
    for (final h in List.of(handlers)) {
      h.onJoinChannelSuccess?.call(_connection, 0);
    }
  }

  @override
  void registerEventHandler(RtcEngineEventHandler eventHandler) => handlers.add(eventHandler);

  @override
  void unregisterEventHandler(RtcEngineEventHandler eventHandler) => handlers.remove(eventHandler);

  @override
  Future<void> startAudioMixing({required String filePath, required bool loopback, required int cycle, int startPos = 0}) async {
    started.add(filePath);
    loopbacks.add(loopback);
  }

  @override
  Future<void> adjustAudioMixingVolume(int volume) async => volumes.add(volume);

  @override
  Future<void> stopAudioMixing() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
