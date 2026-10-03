import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sabalive/core/widgets/permissions_prompt_host.dart';
import 'package:sabalive/services/permissions_flow.dart';

class _FakeGateway implements PermissionGateway {
  _FakeGateway({this.prompted = false});
  bool prompted;
  int requests = 0;
  List<Permission> asked = [];

  @override
  Future<bool> alreadyPrompted() async => prompted;

  @override
  Future<void> markPrompted() async => prompted = true;

  @override
  Future<Map<Permission, PermissionStatus>> request(
      List<Permission> wanted) async {
    requests++;
    asked = wanted;
    return {for (final p in wanted) p: PermissionStatus.granted};
  }
}

void main() {
  group('PermissionsFlow', () {
    test('first run, person agrees: asks for everything, once', () async {
      final g = _FakeGateway();
      final out = await PermissionsFlow(g, isAndroid: true)
          .run(confirm: () async => true);
      expect(out, PermissionPromptOutcome.requested);
      expect(g.requests, 1);
      expect(g.prompted, isTrue);
      expect(
        g.asked,
        [
          Permission.camera,
          Permission.microphone,
          Permission.notification,
        ],
      );
    });

    test('first run, "Not now": no system dialogs, and not asked again',
        () async {
      final g = _FakeGateway();
      final out = await PermissionsFlow(g, isAndroid: true)
          .run(confirm: () async => false);
      expect(out, PermissionPromptOutcome.declined);
      expect(g.requests, 0);
      expect(g.prompted, isTrue);
    });

    test('already asked on this install: neither the explainer nor the system '
        'dialogs appear', () async {
      final g = _FakeGateway(prompted: true);
      var explained = false;
      final out = await PermissionsFlow(g, isAndroid: true).run(confirm: () async {
        explained = true;
        return true;
      });
      expect(out, PermissionPromptOutcome.skipped);
      expect(explained, isFalse);
      expect(g.requests, 0);
    });

    test('a second run after the first never prompts again', () async {
      final g = _FakeGateway();
      final flow = PermissionsFlow(g, isAndroid: true);
      await flow.run(confirm: () async => true);
      final second = await flow.run(confirm: () async => true);
      expect(second, PermissionPromptOutcome.skipped);
      expect(g.requests, 1);
    });

    test('never asks for photo / storage access (system picker is used)', () {
      for (final isAndroid in [true, false]) {
        final wanted =
            PermissionsFlow(_FakeGateway(), isAndroid: isAndroid).wanted;
        expect(wanted, isNot(contains(Permission.photos)));
        expect(wanted, isNot(contains(Permission.videos)));
        expect(wanted, isNot(contains(Permission.storage)));
        expect(wanted, isNot(contains(Permission.audio)));
      }
    });
  });

  group('PermissionsPromptHost', () {
    Widget app(PermissionsFlow flow) => MaterialApp(
          home: PermissionsPromptHost(
            flow: flow,
            child: const Scaffold(body: Text('HOME')),
          ),
        );

    testWidgets('shows the explainer on first run, then requests on Continue',
        (t) async {
      final g = _FakeGateway();
      await t.pumpWidget(app(PermissionsFlow(g, isAndroid: true)));
      await t.pumpAndSettle();

      expect(find.text('Allow access'), findsOneWidget);
      expect(find.text('Camera'), findsOneWidget);
      expect(find.text('Microphone'), findsOneWidget);
      expect(find.text('Notifications'), findsOneWidget);
      expect(find.text('Photos & files'), findsNothing);
      expect(g.requests, 0); // nothing asked until they agree

      await t.tap(find.text('Continue'));
      await t.pumpAndSettle();
      expect(g.requests, 1);
      expect(find.text('Allow access'), findsNothing);
      expect(find.text('HOME'), findsOneWidget);
    });

    testWidgets('"Not now" closes it without asking the system', (t) async {
      final g = _FakeGateway();
      await t.pumpWidget(app(PermissionsFlow(g, isAndroid: true)));
      await t.pumpAndSettle();
      await t.tap(find.text('Not now'));
      await t.pumpAndSettle();
      expect(g.requests, 0);
      expect(g.prompted, isTrue);
    });

    testWidgets('does not show anything once already asked', (t) async {
      final g = _FakeGateway(prompted: true);
      await t.pumpWidget(app(PermissionsFlow(g, isAndroid: true)));
      await t.pumpAndSettle();
      expect(find.text('Allow access'), findsNothing);
      expect(find.text('HOME'), findsOneWidget);
    });
  });
}
