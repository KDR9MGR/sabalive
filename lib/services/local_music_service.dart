import 'dart:async';

import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

/// One song picked from the phone.
class MusicTrack {
  MusicTrack(this.name, this.path);
  final String name;
  final String path;
}

/// Plays songs from the phone's own storage into a live (audio room or video).
///
/// Songs are chosen with the system file picker, which needs no storage permission
/// (the app doesn't request one). They are mixed into the user's published audio
/// with Agora's audio mixing, so everyone in the room hears them — or, with
/// [onlyMe], only this device does. A song is only heard while the user's mic is
/// live (muting the mic mutes the music too, because both ride the same audio
/// stream).
///
/// Used by the host of an audio room only.
class LocalMusicController extends ChangeNotifier {
  LocalMusicController(this.engine) {
    engine.registerEventHandler(_handler);
  }

  final RtcEngine engine;
  late final RtcEngineEventHandler _handler = RtcEngineEventHandler(
    onAudioMixingStateChanged: _onMixingState,
  );

  final List<MusicTrack> queue = [];
  int _index = -1;
  bool _playing = false;
  bool _paused = false;

  /// True from the moment a song is asked to start until the engine confirms it is
  /// playing (or fails) — the sheet shows "Starting…" instead of pretending.
  bool _starting = false;
  Timer? _watchdog;
  int volume = 60;
  bool onlyMe = false;
  String? error;
  bool _disposed = false;

  int get index => _index;
  bool get playing => _playing;
  bool get paused => _paused;
  bool get active => _index >= 0;
  bool get starting => _starting;
  MusicTrack? get current => _index >= 0 && _index < queue.length ? queue[_index] : null;

  /// Opens the system picker; the chosen songs join the queue and, if nothing is
  /// playing, the first of them starts.
  Future<void> pick() async {
    error = null;
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.audio,
      );
      if (files.isEmpty) return;
      final added = <MusicTrack>[
        for (final f in files)
          if (f.path != null) MusicTrack(f.name, f.path!),
      ];
      if (added.isEmpty) {
        error = 'That file could not be opened from here.';
        _notify();
        return;
      }
      final wasIdle = !active;
      queue.addAll(added);
      if (wasIdle) {
        await _playAt(queue.length - added.length);
      } else {
        _notify();
      }
    } catch (e) {
      error = 'Could not open the music picker.';
      debugPrint('LocalMusicController.pick failed: $e');
      _notify();
    }
  }

  Future<void> _playAt(int i) async {
    if (i < 0 || i >= queue.length) {
      await stop();
      return;
    }
    _index = i;
    _paused = false;
    _playing = false;
    _starting = true;
    error = null;
    _notify();
    try {
      await engine.startAudioMixing(
        filePath: queue[i].path,
        loopback: onlyMe,
        cycle: 1,
      );
      await engine.adjustAudioMixingVolume(volume);
      // the engine answers with onAudioMixingStateChanged; if it never does, say so
      _watchdog?.cancel();
      _watchdog = Timer(const Duration(seconds: 6), () {
        if (_disposed || !_starting) return;
        _starting = false;
        error = 'The song did not start. Check the file and your media volume.';
        _notify();
      });
    } catch (e) {
      debugPrint('startAudioMixing failed: $e');
      error = 'Could not play ${queue[i].name} ($e).';
      _starting = false;
      _playing = false;
      // skip a song that won't play rather than stalling the queue
      if (i + 1 < queue.length) {
        _notify();
        return _playAt(i + 1);
      }
    }
    _notify();
  }

  void _onMixingState(AudioMixingStateType state, AudioMixingReasonType reason) {
    debugPrint('audio mixing: $state / $reason');
    if (_disposed || !active) return;
    switch (state) {
      case AudioMixingStateType.audioMixingStatePlaying:
        _watchdog?.cancel();
        _starting = false;
        _playing = true;
        _paused = false;
        error = null;
      case AudioMixingStateType.audioMixingStatePaused:
        _paused = true;
      case AudioMixingStateType.audioMixingStateStopped:
        if (reason == AudioMixingReasonType.audioMixingReasonAllLoopsCompleted) {
          // this song finished: on to the next, or rest at the end of the queue
          if (_index + 1 < queue.length) {
            unawaited(_playAt(_index + 1));
            return;
          }
          _playing = false;
          _paused = false;
        }
      case AudioMixingStateType.audioMixingStateFailed:
        _watchdog?.cancel();
        _starting = false;
        error = switch (reason) {
          AudioMixingReasonType.audioMixingReasonCanNotOpen =>
            'Could not open ${current?.name ?? 'that song'} — the file may be damaged or an unsupported format.',
          AudioMixingReasonType.audioMixingReasonTooFrequentCall =>
            'Songs were started too quickly — wait a moment and try again.',
          _ => 'Could not play ${current?.name ?? 'that song'} ($reason).',
        };
        _playing = false;
        if (_index + 1 < queue.length) {
          unawaited(_playAt(_index + 1));
          return;
        }
    }
    _notify();
  }

  Future<void> pause() async {
    if (!_playing || _paused) return;
    await engine.pauseAudioMixing();
    _paused = true;
    _notify();
  }

  Future<void> resume() async {
    if (!_paused) return;
    await engine.resumeAudioMixing();
    _paused = false;
    _notify();
  }

  Future<void> next() async {
    if (_index + 1 < queue.length) await _playAt(_index + 1);
  }

  Future<void> previous() async {
    if (_index > 0) await _playAt(_index - 1);
  }

  /// Stops the music and empties the queue.
  Future<void> stop() async {
    try {
      await engine.stopAudioMixing();
    } catch (_) {}
    _watchdog?.cancel();
    _starting = false;
    _playing = false;
    _paused = false;
    _index = -1;
    queue.clear();
    _notify();
  }

  Future<void> setVolume(int v) async {
    volume = v.clamp(0, 100);
    try {
      await engine.adjustAudioMixingVolume(volume);
    } catch (_) {}
    _notify();
  }

  /// Plays for this device only, or for the whole room. Takes effect from the next
  /// song (and restarts the current one so the change is heard now).
  Future<void> setOnlyMe(bool v) async {
    if (onlyMe == v) return;
    onlyMe = v;
    if (active && _playing) {
      await _playAt(_index);
    } else {
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _watchdog?.cancel();
    try {
      engine.unregisterEventHandler(_handler);
      unawaited(engine.stopAudioMixing());
    } catch (_) {}
    super.dispose();
  }
}
