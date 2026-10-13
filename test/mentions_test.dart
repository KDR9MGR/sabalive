import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/data/models.dart';
import 'package:sabalive/features/live/widgets/mentions.dart';

AppUser _u(String id, String name) => AppUser(id: id, name: name, username: '@$id');

void main() {
  test('a mention is one word that still reads as the name', () {
    expect(mentionToken('Astro Sharma'), '@Astro Sharma');
    expect(mentionToken(' Riya '), '@Riya');
  });

  group('activeMention', () {
    test('finds what has been typed after the @ under the cursor', () {
      expect(activeMention('hi @Ri', 6), (start: 3, query: 'Ri'));
      expect(activeMention('@', 1), (start: 0, query: ''));
      expect(activeMention('hello @Ri there', 9), (start: 6, query: 'Ri'));
    });

    test('not inside a mention: no @, an @ in the middle of a word, or a space after it', () {
      expect(activeMention('hello', 5), isNull);
      expect(activeMention('mail me a@b.com', 15), isNull);
      expect(activeMention('hi @Riya hello', 14), isNull);
      expect(activeMention('', 0), isNull);
    });
  });

  group('mentionCandidates', () {
    final people = [_u('1', 'Riya'), _u('2', 'Astro Sharma'), _u('3', 'Priya'), _u('4', 'Rishi'), _u('me', 'Mohit')];

    test('names starting with the query come first, then names containing it', () {
      final r = mentionCandidates('ri', people, excludeId: 'me');
      expect([for (final p in r) p.name], ['Riya', 'Rishi', 'Priya']);
    });

    test('an empty query lists people, never yourself, and never twice', () {
      final r = mentionCandidates('', [...people, _u('1', 'Riya')], excludeId: 'me');
      expect(r.length, 4);
      expect(r.any((p) => p.id == 'me'), isFalse);
    });

    test('a name with a space can be typed with the glued space', () {
      expect(mentionCandidates('astro sh', people).single.name, 'Astro Sharma');
    });

    test('capped at the limit', () {
      expect(mentionCandidates('', [for (var i = 0; i < 20; i++) _u('$i', 'User $i')], limit: 5).length, 5);
    });
  });

  group('insertMention', () {
    test('swaps the typed @query for the finished name and a space', () {
      final r = insertMention('hi @Ri', 6, 'Riya')!;
      expect(r.text, 'hi @Riya ');
      expect(r.cursor, 9);
    });

    test('keeps the text after the cursor', () {
      final r = insertMention('hey @Ri how are you', 7, 'Riya Sen')!;
      expect(r.text, 'hey @Riya Sen  how are you');
      expect(r.cursor, 14);
    });

    test('refuses when the message would pass the 60 character limit', () {
      final long = '${'x' * 50} @Ri';
      expect(insertMention(long, long.length, 'Riya Sen'), isNull);
    });

    test('nothing to do when the cursor is not in a mention', () {
      expect(insertMention('hello', 5, 'Riya'), isNull);
    });
  });

  group('parseMentions', () {
    test('splits ordinary words from mentions, in order', () {
      final parts = parseMentions('hi @Riya how are you @Astro Sharma ok');
      expect([for (final p in parts) p.text], ['hi ', '@Riya', ' how are you ', '@Astro Sharma', ' ok']);
      expect([for (final p in parts) p.isMention], [false, true, false, true, false]);
    });

    test('an @ inside a word is not a mention', () {
      expect(parseMentions('a@b.com').single.isMention, isFalse);
      expect(parseMentions('plain').single.text, 'plain');
      expect(parseMentions(''), isEmpty);
    });

    test('a message that is only a mention', () {
      final parts = parseMentions('@Riya');
      expect(parts.single.isMention, isTrue);
    });
  });

  test('mentionsName finds you whatever the capitals and however the spaces were typed', () {
    expect(mentionsName('hi @riya!'.replaceAll('!', ''), 'Riya'), isTrue);
    expect(mentionsName('yo @Astro Sharma', 'astro sharma'), isTrue);
    expect(mentionsName('yo @Riya2', 'Riya'), isFalse);
    expect(mentionsName('no tag here', 'Riya'), isFalse);
    expect(mentionsName('@Riya', ''), isFalse);
  });
}
