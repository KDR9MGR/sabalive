import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/features/live/widgets/wave_colors.dart';

void main() {
  test("the host's ring is always the same green", () {
    expect(waveColorFor('anyone', isHost: true), kHostWaveColor);
    expect(waveColorFor('someone-else', isHost: true), kHostWaveColor);
  });

  test('a guest keeps the same colour every time, and never the host green', () {
    for (final id in ['a', 'b', 'c', '66db08e3-aeb6-4d41-98b7-01da5fe6a83a', 'x' * 40]) {
      final c = waveColorFor(id);
      expect(waveColorFor(id), c, reason: 'stable, not flickering');
      expect(c, isNot(kHostWaveColor));
    }
  });

  test('different guests get a spread of colours', () {
    final colors = {for (var i = 0; i < 200; i++) waveColorFor('user-$i')};
    expect(colors.length, greaterThanOrEqualTo(6));
  });
}
