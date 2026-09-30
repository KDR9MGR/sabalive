import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/data/social_repository.dart';
import 'package:sabalive/features/common/agency_request_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Only the two calls the screen makes; everything else would throw if touched.
class _FakeRepo extends Fake implements SocialRepository {
  _FakeRepo(this.gates, {this.requestError});

  /// Answers hostGate() in order; the last one repeats.
  final List<HostGate> gates;
  final Object? requestError;
  int gateCalls = 0;
  final List<int> requested = [];

  @override
  Future<HostGate> hostGate() async {
    final i = gateCalls < gates.length ? gateCalls : gates.length - 1;
    gateCalls++;
    return gates[i];
  }

  @override
  Future<String> requestGoLive(int agencyDisplayId) async {
    requested.add(agencyDisplayId);
    if (requestError != null) throw requestError!;
    return 'Alpha Agency';
  }
}

HostGate gate({
  bool hasAccess = false,
  bool banned = false,
  String? status,
  String? agency,
}) =>
    (
      hasAccess: hasAccess,
      staff: false,
      banned: banned,
      requestStatus: status,
      requestAgencyName: agency,
    );

Widget _host(_FakeRepo repo) => MaterialApp(
      home: AgencyRequestScreen(
        repo: repo,
        destination: (_) => const Scaffold(body: Text('GO LIVE SETUP')),
      ),
    );

void main() {
  testWidgets('never asked: shows the agency ID form, not a host code',
      (t) async {
    await t.pumpWidget(_host(_FakeRepo([gate()])));
    await t.pump();
    expect(find.text('Enter your agency ID'), findsOneWidget);
    expect(find.text('Send request'), findsOneWidget);
    expect(find.textContaining('code', findRichText: true), findsNothing);
  });

  testWidgets('sending an ID files the request, then shows the waiting state',
      (t) async {
    final repo = _FakeRepo([
      gate(), // first check: nothing yet
      gate(status: 'pending', agency: 'Alpha Agency'), // after sending
    ]);
    await t.pumpWidget(_host(repo));
    await t.pump();

    await t.enterText(find.byType(TextField), '20001');
    await t.tap(find.text('Send request'));
    await t.pump();
    await t.pump();

    expect(repo.requested, [20001]);
    expect(find.text('Request sent'), findsOneWidget);
    expect(find.textContaining('Alpha Agency'), findsWidgets);
    expect(find.text('Check status'), findsOneWidget);
  });

  testWidgets('non-digits are rejected before calling the server', (t) async {
    final repo = _FakeRepo([gate()]);
    await t.pumpWidget(_host(repo));
    await t.pump();
    // the field only accepts digits, so letters leave it empty
    await t.enterText(find.byType(TextField), 'abc');
    await t.tap(find.text('Send request'));
    await t.pump();
    expect(repo.requested, isEmpty);
    expect(find.text('Enter the agency ID, digits only'), findsOneWidget);
  });

  testWidgets('a server error (unknown ID) is shown and the form stays',
      (t) async {
    final repo = _FakeRepo([gate()],
        requestError: const PostgrestException(message: 'No agency found with that ID'));
    await t.pumpWidget(_host(repo));
    await t.pump();
    await t.enterText(find.byType(TextField), '999');
    await t.tap(find.text('Send request'));
    await t.pump();
    await t.pump();
    expect(find.text('No agency found with that ID'), findsOneWidget);
    expect(find.text('Send request'), findsOneWidget);
  });

  testWidgets('declined: says so and lets the user try again', (t) async {
    await t.pumpWidget(_host(_FakeRepo([gate(status: 'rejected', agency: 'Beta')])));
    await t.pump();
    expect(find.textContaining('Beta declined your request'), findsOneWidget);
    expect(find.text('Send request'), findsOneWidget);
  });

  testWidgets('pending: "Check status" re-checks and opens go-live once approved',
      (t) async {
    final repo = _FakeRepo([
      gate(status: 'pending', agency: 'Alpha Agency'),
      gate(hasAccess: true, status: 'approved', agency: 'Alpha Agency'),
    ]);
    await t.pumpWidget(_host(repo));
    await t.pump();
    expect(find.text('Request sent'), findsOneWidget);

    await t.tap(find.text('Check status'));
    await t.pumpAndSettle();
    expect(find.text('GO LIVE SETUP'), findsOneWidget);
  });

  testWidgets('pending: can switch to requesting a different agency', (t) async {
    await t.pumpWidget(
        _host(_FakeRepo([gate(status: 'pending', agency: 'Alpha Agency')])));
    await t.pump();
    await t.tap(find.text('Request a different agency'));
    await t.pump();
    expect(find.text('Enter your agency ID'), findsOneWidget);
  });

  testWidgets('already a host: skips straight to go-live', (t) async {
    await t.pumpWidget(_host(_FakeRepo([gate(hasAccess: true)])));
    await t.pumpAndSettle();
    expect(find.text('GO LIVE SETUP'), findsOneWidget);
  });

  testWidgets('revoked access shows the revoked message, no form', (t) async {
    await t.pumpWidget(_host(_FakeRepo([gate(banned: true)])));
    await t.pump();
    expect(find.text('Access revoked'), findsOneWidget);
    expect(find.text('Send request'), findsNothing);
  });
}
