import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sabalive/app.dart' show UnfocusOnPopup, UnfocusOnPush;
import 'package:sabalive/core/widgets/over_live_route.dart';

/// The chat box keeps focus after it is used; when something opened over the live
/// closed, Flutter handed focus straight back and the keyboard popped up by itself.
class _Live extends StatelessWidget {
  const _Live();
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(children: [
        const Spacer(),
        const TextField(key: Key('chat')),
        ElevatedButton(
          key: const Key('sheet'),
          onPressed: () => showModalBottomSheet<void>(
            context: context,
            builder: (_) => const SizedBox(height: 100, child: Text('sheet')),
          ),
          child: const Text('sheet'),
        ),
        ElevatedButton(
          key: const Key('page'),
          onPressed: () => Navigator.of(context)
              .push(OverLiveRoute<void>(const Scaffold(body: Text('page')))),
          child: const Text('page'),
        ),
        ElevatedButton(
          key: const Key('dialog'),
          onPressed: () => showDialog<void>(
            context: context,
            builder: (_) => const AlertDialog(title: Text('dlg')),
          ),
          child: const Text('dialog'),
        ),
      ]),
    );
  }
}

class _Entry extends OverlayRoute<void> {
  _Entry(this.b);
  final WidgetBuilder b;
  @override
  Iterable<OverlayEntry> createOverlayEntries() =>
      [OverlayEntry(builder: b, maintainState: true)];
}

void main() {
  Future<void> pump(WidgetTester t, {required bool observed}) async {
    await t.pumpWidget(MaterialApp(
      home: const SizedBox(),
      builder: (c, child) => Stack(children: [
        ?child,
        HeroControllerScope.none(
          child: Navigator(
            observers: [if (observed) UnfocusOnPush()],
            onGenerateRoute: (_) => _Entry((_) => const _Live()),
          ),
        ),
      ]),
    ));
    await t.pumpAndSettle();
  }

  Future<void> closeOver(WidgetTester t) async {
    await t.tapAt(const Offset(5, 5));
    await t.pumpAndSettle();
  }

  for (final k in ['sheet', 'page', 'dialog']) {
    testWidgets('the keyboard does not come back after closing a $k', (t) async {
      await pump(t, observed: true);
      await t.tap(find.byKey(const Key('chat')));
      await t.pumpAndSettle();
      expect(t.testTextInput.isVisible, isTrue);

      await t.tap(find.byKey(Key(k)));
      await t.pumpAndSettle();
      await closeOver(t);
      expect(t.testTextInput.isVisible, isFalse, reason: 'keyboard reopened after $k');
    });
  }

  testWidgets('without the observer the keyboard did come back (the bug)', (t) async {
    await pump(t, observed: false);
    await t.tap(find.byKey(const Key('chat')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('sheet')));
    await t.pumpAndSettle();
    await closeOver(t);
    expect(t.testTextInput.isVisible, isTrue);
  });

  testWidgets('typing into the chat box still works normally', (t) async {
    await pump(t, observed: true);
    await t.tap(find.byKey(const Key('chat')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('chat')), 'hello');
    expect(find.text('hello'), findsOneWidget);
    expect(t.testTextInput.isVisible, isTrue);
  });

  testWidgets('popups on ordinary routes drop the keyboard too (PK screens)', (t) async {
    await t.pumpWidget(MaterialApp(
      navigatorObservers: [UnfocusOnPopup()],
      home: Builder(
        builder: (context) => Scaffold(
          body: Column(children: [
            const TextField(key: Key('chat')),
            ElevatedButton(
              key: const Key('sheet'),
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                builder: (_) => const SizedBox(height: 100, child: Text('sheet')),
              ),
              child: const Text('sheet'),
            ),
          ]),
        ),
      ),
    ));
    await t.tap(find.byKey(const Key('chat')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('sheet')));
    await t.pumpAndSettle();
    await t.tapAt(const Offset(5, 5));
    await t.pumpAndSettle();
    expect(t.testTextInput.isVisible, isFalse);
  });
}
