import 'dart:async';

import 'package:flutter/material.dart' hide Text;
import 'package:webview_flutter/webview_flutter.dart';

import '../../data/games_repository.dart';
import '../../core/i18n/text.dart';
import 'game_panel.dart';

/// Why a game screen closed: the person left, or the game asked for the coin shop (`tulasigame://recharge`).
enum GameExit { closed, recharge }

/// A game from the platform, in a WebView, shown as a panel at the bottom of the screen ([GamePanelFrame]; open it with a
/// [GamePanelRoute]). The URL carries the one-time token (never printed or logged). Pages outside the platform's domains are not
/// followed; `tulasigame://exit` closes the screen and `tulasigame://recharge` closes it with [GameExit.recharge] so the caller can
/// open the coin shop. The panel's height follows the game: once the page's engine is up it is asked for its design size
/// ([kDesignSizeScript]) and the panel is resized to fit exactly.
class GameWebViewScreen extends StatefulWidget {
  const GameWebViewScreen({super.key, required this.url, required this.title, this.sizeKey, this.initialAspect, this.measure = true, this.allowSubframes = false});

  final Uri url;
  final String title;

  /// A fixed starting (and, with [measure] false, final) height / width: a SUD game's page has no Cocos engine to ask. Null = the remembered or guessed one.
  final double? initialAspect;

  /// Ask the page for its Cocos design size and follow it (Tulasi games). Off for a SUD game, whose size is the one it was given.
  final bool measure;

  /// A SUD game builds itself from frames and requests of its own hosts: only the TOP page is held to our address, a frame may load any https address.
  final bool allowSubframes;

  /// The game's identification: where what the page reports is remembered, so the next open starts at the right size.
  final String? sizeKey;

  @override
  State<GameWebViewScreen> createState() => _GameWebViewScreenState();
}

class _GameWebViewScreenState extends State<GameWebViewScreen> {
  late final WebViewController _controller;
  bool _loading = true;
  bool _failed = false;
  late double _aspect = widget.initialAspect ?? gameAspectGuess(widget.sizeKey);
  // a game that never says how big it is gets the biggest panel, so none of it is cut off (see [shouldFillPanel])
  bool _fill = false;
  Timer? _measure;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: _onNavigation,
          onPageStarted: (_) {
            if (mounted) setState(() => _loading = true);
          },
          onPageFinished: (_) {
            if (mounted) setState(() => _loading = false);
            if (widget.measure) _startMeasuring();
          },
          onWebResourceError: (e) {
            // a broken picture or script inside the page is the game's business; a page that cannot load at all is ours
            if (e.isForMainFrame ?? false) {
              if (mounted) setState(() => _failed = true);
            }
          },
        ),
      )
      ..loadRequest(widget.url);
  }

  NavigationDecision _onNavigation(NavigationRequest request) {
    if (widget.allowSubframes && !request.isMainFrame && request.url.startsWith('https://')) return NavigationDecision.navigate;
    switch (decideGameNavigation(request.url, gameHost: widget.url.host)) {
      case GameNavigation.allow:
        return NavigationDecision.navigate;
      case GameNavigation.exit:
        _close(GameExit.closed);
        return NavigationDecision.prevent;
      case GameNavigation.recharge:
        _close(GameExit.recharge);
        return NavigationDecision.prevent;
      case GameNavigation.block:
        return NavigationDecision.prevent;
    }
  }

  /// Asks the page for its design size: every half second until it gives a real answer (its engine starts a few seconds after the
  /// page loads, and a game only switches from the engine's template size to its own once loaded, see [kEngineDefaultAspect]),
  /// then every 3 seconds for as long as the screen is open, so a game that changes its stage later is followed.
  void _startMeasuring() {
    _measure?.cancel();
    final started = DateTime.now();
    var settled = false;
    var gotAny = false; // any readable answer at all (the engine's own starting size counts: that is a game that talks, it is just not believed yet)
    _measure = Timer.periodic(const Duration(milliseconds: 500), (t) async {
      if (!mounted) {
        t.cancel();
        return;
      }
      if (settled && t.tick % 6 != 0) return;
      try {
        final aspect = parseDesignAspect(await _controller.runJavaScriptReturningResult(kDesignSizeScript));
        if (aspect != null) gotAny = true;
        if (aspect == null || !mounted || !acceptAspectReading(aspect, DateTime.now().difference(started))) {
          if (mounted && !_fill && shouldFillPanel(hasReading: gotAny, sincePageLoaded: DateTime.now().difference(started))) setState(() => _fill = true);
          return;
        }
        settled = true;
        rememberGameAspect(widget.sizeKey, aspect);
        if (_fill || (aspect - _aspect).abs() > 0.01) {
          setState(() {
            _fill = false; // it has said how big it is: follow it
            _aspect = aspect;
          });
        }
      } catch (_) {
        // the page is not ready for scripts yet: ask again
        if (mounted && !_fill && shouldFillPanel(hasReading: gotAny, sincePageLoaded: DateTime.now().difference(started))) setState(() => _fill = true);
      }
    });
  }

  @override
  void dispose() {
    _measure?.cancel();
    super.dispose();
  }

  void _close(GameExit why) {
    if (mounted) Navigator.of(context).pop(why);
  }

  void _retry() {
    setState(() {
      _failed = false;
      _loading = true;
    });
    _controller.loadRequest(widget.url);
  }

  @override
  Widget build(BuildContext context) {
    return GamePanelFrame(
      title: widget.title,
      aspect: _fill ? gameFillAspect(MediaQuery.of(context)) : _aspect,
      onClose: () => _close(GameExit.closed),
      child: Stack(
        children: [
          Positioned.fill(child: WebViewWidget(controller: _controller)),
          if (_loading && !_failed) const Center(child: CircularProgressIndicator()),
          if (_failed)
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Could not open the game', style: TextStyle(color: Colors.white70)),
                  const SizedBox(height: 12),
                  FilledButton(onPressed: _retry, child: const Text('Retry')),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
