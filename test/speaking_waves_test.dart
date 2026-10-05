import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/features/live/widgets/seat_room.dart';
import 'package:sabalive/features/live/widgets/speaking_waves.dart';
import 'package:sabalive/data/models.dart';

void main() {
  group('waveEnergy', () {
    test('stays between 0 and 1 all the way round and through the loop', () {
      for (var i = 0; i < 48; i++) {
        for (var k = 0; k <= 20; k++) {
          final e = waveEnergy(i / 48, k / 20);
          expect(e, inInclusiveRange(0.0, 1.0));
        }
      }
    });

    test('loops seamlessly: the end of the loop is the start', () {
      for (var i = 0; i < 48; i++) {
        expect(waveEnergy(i / 48, 1), closeTo(waveEnergy(i / 48, 0), 1e-9));
      }
    });

    test('has tall clusters and calm gaps, not a flat ring', () {
      final heights = [for (var i = 0; i < 48; i++) waveEnergy(i / 48, 0.3)];
      final max = heights.reduce((a, b) => a > b ? a : b);
      final min = heights.reduce((a, b) => a < b ? a : b);
      expect(max - min, greaterThan(0.5));
    });
  });

  group('SpeakingWaves', () {
    Widget host(bool active) => MaterialApp(
          home: Center(
            child: SpeakingWaves(
              active: active,
              diameter: 58,
              child: const SizedBox(width: 58, height: 58),
            ),
          ),
        );

    testWidgets('a quiet room runs no animation at all', (t) async {
      await t.pumpWidget(host(false));
      expect(t.binding.transientCallbackCount, 0, reason: 'no ticker is running');
    });

    testWidgets('animates while someone talks and stops again when they stop', (t) async {
      await t.pumpWidget(host(true));
      await t.pump(const Duration(milliseconds: 300));
      expect(t.binding.transientCallbackCount, greaterThan(0), reason: 'the ring is moving');

      await t.pumpWidget(host(false));
      await t.pump(const Duration(milliseconds: 400)); // fades out...
      await t.pump(const Duration(milliseconds: 50)); // ...and the loop stops
      expect(t.binding.transientCallbackCount, 0, reason: 'nothing left animating');
    });

    testWidgets('a seat shows the waves only for its speaker', (t) async {
      Future<void> seat(bool speaking) => t.pumpWidget(MaterialApp(
            home: Scaffold(
              body: Center(
                child: SeatCircle(
                  seat: 1,
                  occupant: AppUser(id: 'u', name: 'Sam', username: '@sam'),
                  speaking: speaking,
                  showLabel: false,
                ),
              ),
            ),
          ));
      await seat(false);
      expect(t.widget<SpeakingWaves>(find.byType(SpeakingWaves)).active, isFalse);
      await seat(true);
      expect(t.widget<SpeakingWaves>(find.byType(SpeakingWaves)).active, isTrue);
      await t.pump(const Duration(seconds: 1));
    });
  });
}
