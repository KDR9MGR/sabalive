import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sabalive/core/i18n/app_language.dart';
import 'package:sabalive/core/i18n/i18n.dart';

/// The PK battle layer's strings (written by Claude, to be reviewed by native speakers): every one has a translation in every
/// language, and the ones with live values keep them.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await I18n.set(languageByCode('en'));
  });

  const plain = [
    'Looking for an opponent…',
    'PK battle',
    'Random',
    'How long',
    'Find an opponent',
    'Invite',
    'PK invite',
    'You won!',
    "It's a draw",
    'The other host left, so you win.',
    'You left the battle.',
    'Back to the live',
    'No opponent found. Try again.',
    'The invite was declined or nobody answered.',
    'The invite is no longer active.',
    'The PK was cancelled.',
    'Video PK is coming soon',
    'Start a PK from Go Live: choose the PK tab',
    'A PK battle is on: if you end now, the other host wins.',
    'A PK battle is already on',
    'Audio PK',
    'Video PK',
    'Video PK (soon)',
    'Start Audio PK',
    'Start Video PK',
    'Nobody you follow is live and free for a PK right now. Try Random.',
    'You are matched with another host who is live right now and looking for a PK. A random PK lasts 5 minutes.',
    'Audio PK: you go live in a voice room, then invite a host you follow or find a random opponent.',
    'Video PK: you go live on camera, then invite a host you follow or find a random opponent. Both cameras show side by side.',
    'WIN',
    'LOSE',
    'Remove seat',
    'Add seat',
    'End PK',
    'End the PK now?',
    'You give up and the other host wins. This cannot be undone.',
    'Ask before someone sits',
    'Request sent. Waiting for the host to accept.',
  ];

  const sameInFilipino = {'PK battle', 'Random', 'Audio PK', 'Video PK', 'PK invite'};

  test('every PK string is translated in every language (English stays as written)', () async {
    for (final l in kLanguages.where((l) => !const {'en', 'en_NG'}.contains(l.code))) {
      await I18n.set(l);
      for (final s in plain) {
        // Filipino keeps a few English terms as they are ("PK battle", "Random"), like the older strings do
        if (l.code == 'fil' && sameInFilipino.contains(s)) continue;
        expect(tr(s), isNot(s), reason: '${l.code}: "$s" has no translation');
      }
    }
  });

  test('strings with live values keep them', () async {
    for (final l in kLanguages.where((l) => !const {'en', 'en_NG'}.contains(l.code))) {
      await I18n.set(l);
      final invite = tr('Asha invites you to a 10 minute PK battle.');
      expect(invite, allOf(contains('Asha'), contains('10')), reason: l.code);
      expect(invite, isNot(contains('{0}')), reason: l.code);
      expect(tr('Final score: 90 – 40'), allOf(contains('90'), contains('40')), reason: l.code);
      expect(tr('12 watching'), contains('12'), reason: l.code);
      expect(tr('10 min'), contains('10'), reason: l.code);
      expect(tr('Waiting for Asha…'), contains('Asha'), reason: l.code);
      expect(tr("Asha's room"), allOf(contains('Asha'), isNot(contains('{0}'))), reason: l.code);
    }
  });

  test('Hindi reads right', () async {
    await I18n.set(languageByCode('hi'));
    expect(tr('You won!'), 'आप जीत गए!');
    expect(tr('Final score: 90 – 40'), 'अंतिम स्कोर: 90 – 40');
  });
}
