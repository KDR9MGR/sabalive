import 'package:flutter/material.dart' hide Text;
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/core/i18n/app_language.dart';
import 'package:sabalive/core/i18n/i18n.dart';
import 'package:sabalive/data/models.dart';
import 'package:sabalive/features/profile/follow_list_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The Fans list: the people who follow each other with this person.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await I18n.set(languageByCode('en'));
  });

  Future<void> open(WidgetTester t, Future<List<AppUser>> Function() loader, {bool fans = true, bool followers = true}) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(home: FollowListScreen(userId: 'u', followers: followers, fans: fans, loader: loader)));
    await t.pump();
  }

  testWidgets('the title is Fans and each fan is a row', (t) async {
    await open(t, () async => [AppUser(id: 'a', name: 'Asha', username: '@a'), AppUser(id: 'b', name: 'Bilal', username: '@b')]);
    expect(find.text('Fans'), findsOneWidget);
    expect(find.text('Asha'), findsOneWidget);
    expect(find.text('Bilal'), findsOneWidget);
  });

  testWidgets('with no fans it says what a fan is', (t) async {
    await open(t, () async => const []);
    expect(find.textContaining('No fans yet'), findsOneWidget);
    expect(find.textContaining('follow you back'), findsOneWidget);
  });

  testWidgets('a failed read shows the error with a retry', (t) async {
    var calls = 0;
    await open(t, () async {
      calls++;
      if (calls == 1) throw Exception('offline');
      return [AppUser(id: 'a', name: 'Asha', username: '@a')];
    });
    expect(find.text('Retry'), findsOneWidget);
    await t.tap(find.text('Retry'));
    await t.pumpAndSettle();
    expect(find.text('Asha'), findsOneWidget);
  });

  testWidgets('the Followers and Following lists keep their own titles', (t) async {
    await open(t, () async => const [], fans: false, followers: true);
    expect(find.text('Followers'), findsOneWidget);
    expect(find.textContaining('No followers yet'), findsOneWidget);
    await open(t, () async => const [], fans: false, followers: false);
    expect(find.text('Following'), findsOneWidget);
  });
}
