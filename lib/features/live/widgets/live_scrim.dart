import 'package:flutter/material.dart';

/// The soft dark gradient a live screen lays over its video so the buttons and the chat stay readable. It is only paint: it takes NO touches.
///
/// That matters. A decorated box is a hit-test target, so a plain `DecoratedBox` over the video catches every tap and nothing under it ever
/// hears one. In a PK battle the viewer's tap on the other host's frame (to go to their room) was swallowed by exactly this layer.
class LiveScrim extends StatelessWidget {
  const LiveScrim({super.key});

  @override
  Widget build(BuildContext context) => const IgnorePointer(
    child: DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black54, Colors.transparent, Colors.black54, Colors.black87],
          stops: [0, 0.25, 0.7, 1],
        ),
      ),
    ),
  );
}
