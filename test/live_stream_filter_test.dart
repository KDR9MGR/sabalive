import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/data/models.dart';

LiveStream _live(LiveMode mode) => LiveStream(
  id: 's',
  host: AppUser(id: 'h', name: 'H', username: '@h'),
  title: 't',
  category: 'Chatting',
  viewers: 0,
  mode: mode,
);

void main() {
  test('Video and Audio list lives of that kind, battle or not', () {
    final audio = _live(LiveMode.audio)..inBattle = true;
    expect(audio.isIn(LiveMode.audio), isTrue);
    expect(audio.isIn(LiveMode.video), isFalse);
    expect(_live(LiveMode.video).isIn(LiveMode.video), isTrue);
  });

  test('PK lists the old PK-mode lives and any live that is in a battle now', () {
    expect(_live(LiveMode.pk).isIn(LiveMode.pk), isTrue);
    expect(_live(LiveMode.audio).isIn(LiveMode.pk), isFalse);
    expect((_live(LiveMode.audio)..inBattle = true).isIn(LiveMode.pk), isTrue);
    expect((_live(LiveMode.video)..inBattle = true).isIn(LiveMode.pk), isTrue);
  });
}
