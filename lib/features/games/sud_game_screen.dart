import 'dart:async';

import 'package:flutter/material.dart' hide Text;

import '../../core/i18n/text.dart';
import 'game_panel.dart';
import 'game_webview_screen.dart' show GameExit;
import 'sud_bridge.dart';
import 'sud_launch.dart';

/// A SUD game, played in SUD's NATIVE SDK (their plugin) inside the game panel: the same panel as every other game ([GamePanelFrame], opened with [showGamePanel]), with the
/// native game view filling it. SUD does not accept our web-SDK page (error 10005 for every game; their team confirmed the games are for Android and iOS), so this replaced it.
///
/// What it does: create the native view -> `initSDK` -> `loadGame` with the values from the launch ([SudLaunch]); show the loading progress; renew the login code when SUD says it
/// expired; pause when the app goes to the background and resume when it returns; close when the game says "back to lobby"; and on a failure say so with SUD's number and offer
/// Retry. The game is destroyed and the view freed when the screen closes.
class SudGameScreen extends StatefulWidget {
  const SudGameScreen({
    super.key,
    required this.launch,
    required this.title,
    required this.aspect,
    @visibleForTesting this.bridge,
    @visibleForTesting this.renewCode = renewSudCode,
    @visibleForTesting this.loadTimeout = kSudLoadTimeout,
  });

  final SudLaunch launch;
  final String title;

  /// The panel's height / width (SUD's minimum size table, kept per game in the panel).
  final double aspect;

  /// Replaces SUD's SDK (tests).
  final SudBridge? bridge;
  final SudCodeRenewer renewCode;
  final Duration loadTimeout;

  @override
  State<SudGameScreen> createState() => _SudGameScreenState();
}

enum _Phase { loading, playing, failed }

class _SudGameScreenState extends State<SudGameScreen> with WidgetsBindingObserver {
  late final SudBridge _bridge = widget.bridge ?? PluginSudBridge();
  final GlobalKey _viewKey = GlobalKey();
  int? _viewId;
  _Phase _phase = _Phase.loading;
  int _progress = 0;
  String _message = '';
  Timer? _timeout;
  int _attempt = 0;
  bool _renewing = false;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timeout?.cancel();
    _attempt++; // anything still answering is ignored
    final id = _viewId;
    if (id != null) unawaited(_bridge.release(id));
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final id = _viewId;
    if (id == null || !_running) return;
    if (state == AppLifecycleState.paused) {
      unawaited(_bridge.pause(id));
    } else if (state == AppLifecycleState.resumed) {
      unawaited(_bridge.resume(id));
    }
  }

  void _onViewCreated(int id) {
    _viewId = id;
    // the game can only be loaded after the native view exists, and its size is only known after it was laid out
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_start());
    });
  }

  ({int width, int height}) _pixels() {
    final box = _viewKey.currentContext?.findRenderObject();
    final ratio = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
    if (box is RenderBox && box.hasSize) return (width: (box.size.width * ratio).round(), height: (box.size.height * ratio).round());
    final size = MediaQuery.sizeOf(context);
    return (width: (size.width * ratio).round(), height: (size.width * widget.aspect * ratio).round());
  }

  Future<void> _start() async {
    final id = _viewId;
    if (id == null) return;
    final attempt = ++_attempt;
    setState(() {
      _phase = _Phase.loading;
      _progress = 0;
      _message = '';
    });
    _timeout?.cancel();
    _timeout = Timer(widget.loadTimeout, () {
      if (mounted && attempt == _attempt && _phase == _Phase.loading) _fail(kSudTimeoutMessage);
    });
    final l = widget.launch;
    try {
      final init = await _bridge.init(appId: l.appId, appKey: l.appKey, userId: l.userId, testEnv: l.testEnv);
      if (!mounted || attempt != _attempt) return;
      if (!init.ok) return _fail(sudStartFailure(init.code));
      final px = _pixels();
      final loaded = await _bridge.load(
        id,
        l,
        viewInfoJson: sudViewInfoJson(px.width, px.height),
        configJson: sudGameConfigJson(),
        events: SudGameEvents(
          onLoading: (progress, retCode) {
            if (mounted && attempt == _attempt && retCode == 0 && _phase == _Phase.loading) setState(() => _progress = progress.clamp(0, 100));
          },
          onStarted: () {
            if (!mounted || attempt != _attempt) return;
            _timeout?.cancel();
            _running = true;
            setState(() => _phase = _Phase.playing);
          },
          onExpireCode: _renew,
          onState: (state, _) {
            if (state == kSudBackLobbyState) _close();
          },
        ),
      );
      if (!mounted || attempt != _attempt) return;
      if (!loaded.ok) _fail(sudStartFailure(loaded.code));
    } catch (_) {
      if (mounted && attempt == _attempt) _fail(sudStartFailure(null));
    }
  }

  void _fail(String message) {
    _timeout?.cancel();
    _running = false;
    if (mounted) {
      setState(() {
        _phase = _Phase.failed;
        _message = message;
      });
    }
  }

  /// The login code lives two hours: get a new one from our server (proved by the launch token) and hand it to the game.
  Future<void> _renew() async {
    final id = _viewId;
    if (id == null || _renewing) return;
    _renewing = true;
    try {
      final code = await widget.renewCode(widget.launch);
      if (code != null && mounted) await _bridge.updateCode(id, code);
    } finally {
      _renewing = false;
    }
  }

  Future<void> _retry() async {
    final id = _viewId;
    if (id == null) return;
    _running = false;
    try {
      await _bridge.destroy(id); // a new game can only be loaded after the old one is destroyed
    } catch (_) {}
    if (mounted) unawaited(_start());
  }

  void _close() {
    if (mounted) Navigator.of(context).pop(GameExit.closed);
  }

  @override
  Widget build(BuildContext context) {
    return GamePanelFrame(
      title: widget.title,
      aspect: widget.aspect,
      onClose: _close,
      child: Stack(
        children: [
          Positioned.fill(key: _viewKey, child: _bridge.buildView(_onViewCreated)),
          if (_phase == _Phase.loading)
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  if (_progress > 0) ...[
                    const SizedBox(height: 10),
                    Text('$_progress%', key: const ValueKey('sud-progress'), style: const TextStyle(color: Colors.white70)),
                  ],
                ],
              ),
            ),
          if (_phase == _Phase.failed)
            Positioned.fill(
              child: ColoredBox(
                color: Colors.black,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_message, key: const ValueKey('sud-failure'), textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70)),
                        const SizedBox(height: 12),
                        FilledButton(onPressed: _retry, child: const Text('Retry')),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
