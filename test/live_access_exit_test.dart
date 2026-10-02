import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sabalive/features/live/live_access_exit.dart';
import 'package:sabalive/state/active_live_session_controller.dart';

void main() {
  Widget host(ActiveLiveSessionController session, void Function(BuildContext) onTap) =>
      ChangeNotifierProvider.value(
        value: session,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(onPressed: () => onTap(context), child: const Text('go')),
            ),
          ),
        ),
      );

  testWidgets('leaving a live because of a ban says why and ends the session', (t) async {
    final session = ActiveLiveSessionController()
      ..start(roomId: 'r1', hostName: 'Host', builder: (_) => const SizedBox());
    expect(session.isActive, isTrue);
    await t.pumpWidget(host(session, (c) => leaveLiveBecauseDenied(c, 'You are banned from live permanently.')));
    await t.tap(find.text('go'));
    await t.pump();
    expect(find.text('You are banned from live permanently.'), findsOneWidget);
    expect(session.isActive, isFalse);
  });

  testWidgets('a PK battle (an ordinary route) is popped instead', (t) async {
    final session = ActiveLiveSessionController();
    await t.pumpWidget(
      ChangeNotifierProvider.value(
        value: session,
        child: MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => Scaffold(
                    body: Builder(
                      builder: (inner) => TextButton(
                        onPressed: () => leaveLiveBecauseDenied(inner, 'The host removed you from this live.', popRoute: true),
                        child: const Text('inside'),
                      ),
                    ),
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    expect(find.text('inside'), findsOneWidget);
    await t.tap(find.text('inside'));
    await t.pumpAndSettle();
    expect(find.text('inside'), findsNothing);
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('the blocked dialog shows the reason and closes with OK', (t) async {
    final session = ActiveLiveSessionController();
    await t.pumpWidget(host(session, (c) => showLiveBlockedDialog(c, 'This device is banned until 09 Oct 2026.')));
    await t.tap(find.text('go'));
    await t.pumpAndSettle();
    expect(find.text('Live unavailable'), findsOneWidget);
    expect(find.text('This device is banned until 09 Oct 2026.'), findsOneWidget);
    await t.tap(find.text('OK'));
    await t.pumpAndSettle();
    expect(find.text('Live unavailable'), findsNothing);
  });
}
