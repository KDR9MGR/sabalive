import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:sabalive/app.dart';
import 'package:sabalive/config/supabase_config.dart';
import 'package:sabalive/features/splash/splash_screen.dart';

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: SupabaseConfig.url,
      publishableKey: SupabaseConfig.publishableKey,
    );
  });

  testWidgets('App boots to the splash screen', (WidgetTester tester) async {
    await tester.pumpWidget(const SabaLiveApp());
    await tester.pump();

    expect(find.byType(SplashScreen), findsOneWidget);
  });
}
