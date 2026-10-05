import 'dart:math' as math;
import 'dart:ui' show PointMode;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// How tall the bar at [x] (0..1 around the ring) stands at loop time [t] (0..1), as a
/// fraction 0..1. A few travelling sine waves added together and sharpened, so tall bars
/// come in moving clusters with calm gaps between them — the look of a circular audio
/// spectrum. Every wave moves a whole number of cycles per loop, so the loop is seamless.
@visibleForTesting
double waveEnergy(double x, double t) {
  const tau = math.pi * 2;
  final v = 0.50 * math.sin(tau * (2 * x - t)) +
      0.30 * math.sin(tau * (5 * x + 2 * t) + 1.3) +
      0.20 * math.sin(tau * (9 * x - 3 * t) + 0.4);
  return math.pow((v + 1) / 2, 2.4).toDouble();
}

/// A ring of bars that ripples around [child] while [active] — a circular audio spectrum
/// that shows who is talking. It grows in when someone starts, settles out when they stop,
/// and runs no animation at all while nobody is speaking (so a quiet room costs nothing).
///
/// [diameter] is the size of [child]; the bars stand just outside its edge. Agora only
/// reports how loud someone is, not their sound's spectrum, so the shape is generated; the
/// ring is on exactly while the person is heard.
class SpeakingWaves extends StatefulWidget {
  const SpeakingWaves({
    super.key,
    required this.active,
    required this.diameter,
    required this.child,
    this.color = Colors.white,
    this.bars = 48,
  });

  final bool active;
  final double diameter;
  final Widget child;
  final Color color;
  final int bars;

  @override
  State<SpeakingWaves> createState() => _SpeakingWavesState();
}

class _SpeakingWavesState extends State<SpeakingWaves> with TickerProviderStateMixin {
  late final AnimationController _flow = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );
  late final AnimationController _level = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  )..addStatusListener((status) {
      // nobody talking and the ring has faded out: stop animating altogether
      if (status == AnimationStatus.dismissed) _flow.stop();
    });

  @override
  void initState() {
    super.initState();
    if (widget.active) _start();
  }

  @override
  void didUpdateWidget(SpeakingWaves old) {
    super.didUpdateWidget(old);
    if (widget.active == old.active) return;
    widget.active ? _start() : _level.reverse();
  }

  void _start() {
    if (!_flow.isAnimating) _flow.repeat();
    _level.forward();
  }

  @override
  void dispose() {
    _flow.dispose();
    _level.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.diameter,
      height: widget.diameter,
      child: CustomPaint(
        // painted behind the child, outside its edge, so it never covers the picture
        painter: _WavesPainter(
          flow: _flow,
          level: _level,
          diameter: widget.diameter,
          color: widget.color,
          bars: widget.bars,
        ),
        child: widget.child,
      ),
    );
  }
}

class _WavesPainter extends CustomPainter {
  _WavesPainter({
    required this.flow,
    required this.level,
    required this.diameter,
    required this.color,
    required this.bars,
  }) : super(repaint: Listenable.merge([flow, level]));

  final Animation<double> flow;
  final Animation<double> level;
  final double diameter;
  final Color color;
  final int bars;

  @override
  void paint(Canvas canvas, Size size) {
    final grow = Curves.easeOut.transform(level.value);
    if (grow <= 0) return;
    final center = size.center(Offset.zero);
    final inner = diameter / 2 + diameter * 0.03;
    final tallest = math.max(4.0, diameter * 0.2);
    const shortest = 1.1; // a dot: the ring is visible even between the peaks
    final t = flow.value;

    final points = Float32List(bars * 4);
    for (var i = 0; i < bars; i++) {
      final x = i / bars;
      final angle = -math.pi / 2 + x * math.pi * 2;
      final length = shortest + (tallest - shortest) * waveEnergy(x, t) * grow;
      final dx = math.cos(angle), dy = math.sin(angle);
      points[i * 4] = center.dx + dx * inner;
      points[i * 4 + 1] = center.dy + dy * inner;
      points[i * 4 + 2] = center.dx + dx * (inner + length);
      points[i * 4 + 3] = center.dy + dy * (inner + length);
    }
    final paint = Paint()
      ..color = color.withValues(alpha: 0.35 + 0.65 * grow)
      ..strokeWidth = (diameter * 0.04).clamp(1.5, 2.8)
      ..strokeCap = StrokeCap.round;
    canvas.drawRawPoints(PointMode.lines, points, paint);
  }

  @override
  bool shouldRepaint(_WavesPainter old) =>
      old.diameter != diameter || old.color != color || old.bars != bars;
}
