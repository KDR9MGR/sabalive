import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/data/models.dart';
import 'package:sabalive/data/social_repository.dart';
import 'package:sabalive/features/profile/user_safety_menu.dart';

class _FakeSocial extends SocialRepository {
  final blocked = <String>[];
  final reports = <(String, String, String)>[];
  bool failBlock = false;

  @override
  Future<void> block(String userId) async {
    if (failBlock) throw Exception('network down');
    blocked.add(userId);
  }

  @override
  Future<void> report({
    required String targetType,
    required String targetId,
    required String reason,
    String? note,
  }) async => reports.add((targetType, targetId, reason));
}

final _sam = AppUser(id: 'sam-id', name: 'Sam', username: '@sam');

/// A "chat" page pushed over a home page, with an ellipsis that opens the menu.
Future<void> _open(WidgetTester t, _FakeSocial repo, {VoidCallback? onViewProfile}) async {
  await t.pumpWidget(MaterialApp(
    home: Builder(
      builder: (home) => Scaffold(
        body: TextButton(
          onPressed: () => Navigator.of(home).push(MaterialPageRoute<void>(
            builder: (_) => Builder(
              builder: (chat) => Scaffold(
                appBar: AppBar(title: const Text('chat'), actions: [
                  IconButton(
                    onPressed: () => showUserSafetyMenu(
                      chat, _sam, onViewProfile: onViewProfile, repo: repo),
                    icon: const Icon(Icons.more_vert_rounded),
                  ),
                ]),
              ),
            ),
          )),
          child: const Text('open'),
        ),
      ),
    ),
  ));
  await t.tap(find.text('open'));
  await t.pumpAndSettle();
  await t.tap(find.byIcon(Icons.more_vert_rounded));
  await t.pumpAndSettle();
}

void main() {
  testWidgets('the ellipsis opens a menu; View profile only when offered', (t) async {
    await _open(t, _FakeSocial());
    expect(find.text('Block'), findsOneWidget);
    expect(find.text('Report'), findsOneWidget);
    expect(find.text('View profile'), findsNothing);
  });

  testWidgets('View profile calls back', (t) async {
    var opened = 0;
    await _open(t, _FakeSocial(), onViewProfile: () => opened++);
    await t.tap(find.text('View profile'));
    await t.pumpAndSettle();
    expect(opened, 1);
  });

  testWidgets('Report asks for a reason and files it against the user', (t) async {
    final repo = _FakeSocial();
    await _open(t, repo);
    await t.tap(find.text('Report'));
    await t.pumpAndSettle();
    await t.tap(find.text('Spam or scam'));
    await t.pumpAndSettle();
    expect(repo.reports, [('user', 'sam-id', 'Spam or scam')]);
    expect(find.text('Report submitted — thank you'), findsOneWidget);
  });

  testWidgets('Block blocks the user and leaves the chat', (t) async {
    final repo = _FakeSocial();
    await _open(t, repo);
    await t.tap(find.text('Block'));
    await t.pumpAndSettle();
    expect(repo.blocked, ['sam-id']);
    expect(find.text('chat'), findsNothing, reason: 'back on the home page');
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('a failed block stays on the chat and says so', (t) async {
    final repo = _FakeSocial()..failBlock = true;
    await _open(t, repo);
    await t.tap(find.text('Block'));
    await t.pumpAndSettle();
    expect(find.text('chat'), findsOneWidget);
    expect(find.byType(SnackBar), findsOneWidget);
  });
}
