import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/core/utils/share_links.dart';

void main() {
  const id = '2b8f3c1e-5d4a-4c8e-9f21-7a6b5c4d3e2f';

  test('a shared live link is a real https link, not a custom scheme', () {
    final url = liveShareUrl(id);
    expect(url, 'https://sabalive.in/live/$id');
    expect(Uri.parse(url).scheme, 'https');
  });

  group('the invite link', () {
    test('is one link of our own site that sends each phone to its store (not a Play link that is no use on an iPhone)', () {
      final u = Uri.parse(inviteShareUrl('ABC123'));
      expect(u.scheme, 'https');
      expect(u.host, 'sabalive.in');
      expect(u.path, '/invite/ABC123');
      expect(u.hasQuery, isFalse);
    });

    test('the code is cleaned: nothing can break out of the link', () {
      final u = inviteShareUrl('AB C&1=2/../x');
      expect(u, 'https://sabalive.in/invite/ABC12x');
      expect(u, isNot(contains(' ')));
      expect(Uri.parse(u).pathSegments, ['invite', 'ABC12x']);
    });

    test('an empty code still gives a link that works (the page without a code)', () {
      expect(inviteShareUrl(''), 'https://sabalive.in/invite');
      expect(inviteShareUrl('///'), 'https://sabalive.in/invite');
    });

    test('the share message says the code and holds the link', () {
      final t = inviteShareText('ABC123');
      expect(t, contains('ABC123'));
      expect(t, contains(inviteShareUrl('ABC123')));
      expect(t, isNot(contains('sabalive.app')), reason: 'the old, dead address');
      expect(t, isNot(contains('play.google.com')), reason: 'the page decides which store');
    });
  });

  group('liveIdFromUri', () {
    test('reads the id from the shared https link', () {
      expect(liveIdFromUri(Uri.parse(liveShareUrl(id))), id);
    });

    test('also from www., and from http', () {
      expect(liveIdFromUri(Uri.parse('https://www.sabalive.in/live/$id')), id);
      expect(liveIdFromUri(Uri.parse('http://sabalive.in/live/$id')), id);
    });

    test('and still from the older sabalive:// link', () {
      expect(liveIdFromUri(Uri.parse('sabalive://live/$id')), id);
    });

    test('ignores query strings and trailing paths', () {
      expect(liveIdFromUri(Uri.parse('https://sabalive.in/live/$id?utm=wa')), id);
      expect(liveIdFromUri(Uri.parse('https://sabalive.in/live/$id/')), id);
    });

    test('ignores other pages, other sites and other schemes', () {
      expect(liveIdFromUri(Uri.parse('https://sabalive.in/about')), isNull);
      expect(liveIdFromUri(Uri.parse('https://sabalive.in/live')), isNull);
      expect(liveIdFromUri(Uri.parse('https://sabalive.in/')), isNull);
      expect(liveIdFromUri(Uri.parse('https://evil.example/live/$id')), isNull);
      expect(liveIdFromUri(Uri.parse('https://sabalive.in.evil.example/live/$id')), isNull);
      expect(liveIdFromUri(Uri.parse('com.sabalive.in://login-callback/')), isNull);
      expect(liveIdFromUri(Uri.parse('sabalive://profile/$id')), isNull);
    });

    test('an id that is not a real stream id is rejected', () {
      expect(liveIdFromUri(Uri.parse('https://sabalive.in/live/nisha')), isNull);
      expect(liveIdFromUri(Uri.parse('sabalive://live/s1')), isNull);
      expect(liveIdFromUri(Uri.parse('https://sabalive.in/live/..%2F..')), isNull);
    });
  });
}
