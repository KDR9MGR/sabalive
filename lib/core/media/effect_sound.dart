import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart' show debugPrint;

import 'effect_file_cache.dart';

/// One sound that is playing alongside a gift / entry effect. [stop] ends it (and is safe to repeat).
abstract class EffectSound {
  Future<void> stop();
}

typedef EffectSoundStarter = EffectSound Function(String url);

/// Starts the sound a panel attached to a gift or an entry effect.
///
/// It mixes with the live's own audio (no audio focus is taken, so the host's voice is not paused or
/// ducked) and plays the stored copy of the file when there is one. Tests replace [start].
class EffectSounds {
  EffectSounds._();

  /// How a sound is started; tests swap this for a recorder.
  static EffectSoundStarter starter = _AudioplayersSound.new;

  static EffectSound start(String url) => starter(url);
}

class _AudioplayersSound implements EffectSound {
  _AudioplayersSound(String url) {
    unawaited(_run(url));
  }

  AudioPlayer? _player;
  bool _stopped = false;

  Future<void> _run(String url) async {
    try {
      final player = AudioPlayer();
      _player = player;
      await player.setAudioContext(AudioContextConfig(focus: AudioContextConfigFocus.mixWithOthers).build());
      await player.setReleaseMode(ReleaseMode.stop);
      final file = await EffectFileCache.instance.cached(url);
      if (_stopped) {
        await player.dispose();
        return;
      }
      await player.play(file != null ? DeviceFileSource(file.path) : UrlSource(url));
    } catch (e) {
      debugPrint('effect sound failed: $e');
    }
  }

  @override
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    final player = _player;
    if (player == null) return;
    try {
      await player.stop();
      await player.dispose();
    } catch (_) {}
  }
}
