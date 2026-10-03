import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/core/utils/share_links.dart';

void main() {
  const id = '2b8f3c1e-5d4a-4c8e-9f21-7a6b5c4d3e2f';

  test('a shared live link is a real https link, not a custom scheme', () {
    final url = liveShareUrl(id);
    expect(url, 'https://sabalive.in/live/$id');
    expect(Uri.parse(url).scheme, 'https');
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
