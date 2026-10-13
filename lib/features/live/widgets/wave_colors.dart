import 'package:flutter/painting.dart';

/// The speaking ring of the room's host is always this green.
const Color kHostWaveColor = Color(0xFF22C55E);

// bright colours that read on a dark room and are clearly not the host's green
const List<Color> _guestWaveColors = [
  Color(0xFFF472B6), // pink
  Color(0xFF38BDF8), // sky
  Color(0xFFFB923C), // orange
  Color(0xFFFACC15), // yellow
  Color(0xFFA78BFA), // violet
  Color(0xFFF87171), // red
  Color(0xFF22D3EE), // cyan
  Color(0xFFE879F9), // magenta
];

/// The colour of someone's speaking ring: green for the host, and for everyone else a colour picked from their id,
/// so each person keeps the same colour all the time instead of flickering between colours.
Color waveColorFor(String userId, {bool isHost = false}) {
  if (isHost) return kHostWaveColor;
  var h = 0;
  for (final u in userId.codeUnits) {
    h = (h * 31 + u) & 0x7FFFFFFF;
  }
  return _guestWaveColors[h % _guestWaveColors.length];
}
