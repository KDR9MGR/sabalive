import 'package:flutter_test/flutter_test.dart';

import 'package:sabalive/app.dart';

void main() {
  testWidgets('App boots to the splash screen', (WidgetTester tester) async {
    await tester.pumpWidget(const SabaLiveApp());
    await tester.pump();

    expect(find.text('Go Live. Be a Star!'), findsOneWidget);
  });
}
