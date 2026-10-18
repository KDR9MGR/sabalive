import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/core/utils/auth_links.dart';
import 'package:sabalive/services/deep_link_service.dart';

void main() {
  group('isAuthCallbackUri', () {
    test('the link Supabase sends the browser back with, whatever it appends', () {
      expect(isAuthCallbackUri(Uri.parse('com.sabalive.in://login-callback/')), isTrue);
      expect(isAuthCallbackUri(Uri.parse('com.sabalive.in://login-callback/?code=abc')), isTrue);
      expect(isAuthCallbackUri(Uri.parse('com.sabalive.in://login-callback#access_token=x&type=signup')), isTrue);
    });

    test('nothing else: live links, other hosts, other schemes', () {
      expect(isAuthCallbackUri(Uri.parse('sabalive://live/0b1c2d3e-0000-4000-8000-000000000000')), isFalse);
      expect(isAuthCallbackUri(Uri.parse('https://sabalive.in/live/0b1c2d3e-0000-4000-8000-000000000000')), isFalse);
      expect(isAuthCallbackUri(Uri.parse('com.sabalive.in://somewhere-else/')), isFalse);
      expect(isAuthCallbackUri(Uri.parse('com.other.app://login-callback/')), isFalse);
    });
  });

  group('DeepLinkService and the sign-in browser', () {
    test('the auth callback closes the sign-in browser, once, and opens nothing', () async {
      var closed = 0;
      final service = DeepLinkService(GlobalKey<NavigatorState>(), closeSignInBrowser: () async => closed++);
      await service.handle(Uri.parse('com.sabalive.in://login-callback/?code=abc'));
      expect(closed, 1);
    });

    test('a link that is not the callback leaves the browser alone', () async {
      var closed = 0;
      final service = DeepLinkService(GlobalKey<NavigatorState>(), closeSignInBrowser: () async => closed++);
      await service.handle(Uri.parse('https://example.com/'));
      await service.handle(Uri.parse('sabalive://live/not-an-id'));
      expect(closed, 0);
    });
  });
}
