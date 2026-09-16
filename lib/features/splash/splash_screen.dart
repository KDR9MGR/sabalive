import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import '../../state/auth_controller.dart';
import '../../theme/app_colors.dart';

/// Brand intro video (baked to 1.5× in `assets/video/splash.mp4`). When it
/// finishes — or after a hard timeout, or if it can't load — the app moves on.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  VideoPlayerController? _controller;
  Timer? _failsafe;
  bool _advanced = false;

  @override
  void initState() {
    super.initState();
    // Never hang on the splash even if the video stalls.
    _failsafe = Timer(const Duration(seconds: 16), _advance);
    _start();
  }

  Future<void> _start() async {
    try {
      final c = VideoPlayerController.asset('assets/video/splash.mp4');
      _controller = c;
      await c.initialize();
      await c.setVolume(1);
      await c.setLooping(false);
      c.addListener(_onTick);
      if (!mounted) return;
      setState(() {});
      await c.play();
    } catch (_) {
      _advance();
    }
  }

  void _onTick() {
    final c = _controller;
    if (c == null) return;
    final v = c.value;
    if (v.isInitialized &&
        !v.isPlaying &&
        v.position >= v.duration - const Duration(milliseconds: 120)) {
      _advance();
    }
  }

  void _advance() {
    if (_advanced || !mounted) return;
    _advanced = true;
    context.read<AuthController>().completeSplash();
  }

  @override
  void dispose() {
    _failsafe?.cancel();
    _controller?.removeListener(_onTick);
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    final ready = c != null && c.value.isInitialized;
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: _advance, // let impatient users skip
        child: SizedBox.expand(
          // stretch the clip to fill the whole screen (no letterbox bars)
          child: ready
              ? VideoPlayer(c)
              : const Center(
                  child: CircularProgressIndicator(
                      color: AppColors.primaryBright),
                ),
        ),
      ),
    );
  }
}
