import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sabalive/data/messages_repository.dart';
import 'package:sabalive/data/models.dart';
import 'package:sabalive/features/messages/messages_screen.dart';

/// Only what the screen calls; anything else would throw if touched.
class _FakeRepo extends Fake implements MessagesRepository {
  List<ConversationSummary> all = [];
  Object? failWith;
  int inboxCalls = 0;
  void Function()? pushChange;
  bool stopped = false;

  @override
  Future<List<ConversationSummary>> inbox({required bool requests}) async {
    inboxCalls++;
    if (failWith != null) throw failWith!;
    return requests ? const [] : all;
  }

  @override
  void Function() watchInbox(void Function() onChange) {
    pushChange = onChange;
    return () => stopped = true;
  }
}

ConversationSummary convo(String name) => ConversationSummary(
      conversationId: 'c-$name',
      other: AppUser(id: 'u-$name', name: name, username: '@$name'),
      lastMessage: 'hello from $name',
      lastAt: DateTime.now(),
      unread: false,
      pending: false,
      lastFromMe: false,
    );

Widget host(_FakeRepo repo, ValueNotifier<int> tab) => MaterialApp(
      home: MessagesScreen(
        repo: repo,
        refreshOn: tab,
        isActive: () => tab.value == 1,
      ),
    );

void main() {
  testWidgets('loads the inbox when the tab first opens', (t) async {
    final repo = _FakeRepo()..all = [convo('Astro')];
    await t.pumpWidget(host(repo, ValueNotifier(1)));
    await t.pump();
    expect(find.text('Astro'), findsWidgets);
    expect(repo.inboxCalls, 2); // All + Requests
  });

  testWidgets(
      'a chat started elsewhere appears when you come back to the tab',
      (t) async {
    final repo = _FakeRepo(); // empty at start, like the reported screen
    final tab = ValueNotifier<int>(1);
    await t.pumpWidget(host(repo, tab));
    await t.pump();
    expect(find.textContaining('No conversations yet'), findsOneWidget);

    tab.value = 0; // user leaves the Messages tab...
    await t.pump();
    final callsWhileAway = repo.inboxCalls;

    repo.all = [convo('Riya')]; // ...and starts a chat from a profile/live room
    tab.value = 1; // comes back
    await t.pump();
    await t.pump();

    expect(find.text('Riya'), findsWidgets);
    expect(repo.inboxCalls, greaterThan(callsWhileAway));
  });

  testWidgets('does not reload while the tab is hidden', (t) async {
    final repo = _FakeRepo()..all = [convo('Astro')];
    final tab = ValueNotifier<int>(1);
    await t.pumpWidget(host(repo, tab));
    await t.pump();
    final before = repo.inboxCalls;
    tab.value = 0;
    await t.pump();
    tab.value = 2; // moving between other tabs shouldn't touch the inbox
    await t.pump();
    expect(repo.inboxCalls, before);
  });

  testWidgets('a new message arriving updates the list live (debounced)',
      (t) async {
    final repo = _FakeRepo()..all = [convo('Astro')];
    await t.pumpWidget(host(repo, ValueNotifier(1)));
    await t.pump();
    expect(find.text('Riya'), findsNothing);

    repo.all = [convo('Riya'), convo('Astro')];
    repo.pushChange!(); // realtime: a message was inserted
    repo.pushChange!(); // a burst collapses into one reload
    final before = repo.inboxCalls;
    await t.pump(const Duration(milliseconds: 500));
    await t.pump();

    expect(find.text('Riya'), findsWidgets);
    expect(repo.inboxCalls - before, 2); // one reload = All + Requests
  });

  testWidgets('a failed background reload keeps the list on screen', (t) async {
    final repo = _FakeRepo()..all = [convo('Astro')];
    final tab = ValueNotifier<int>(1);
    await t.pumpWidget(host(repo, tab));
    await t.pump();

    repo.failWith = Exception('offline');
    repo.pushChange!();
    await t.pump(const Duration(milliseconds: 500));
    await t.pump();

    expect(find.text('Astro'), findsWidgets); // still there, not an error page
    expect(find.textContaining('offline'), findsNothing);
  });

  testWidgets('stops listening when the screen goes away', (t) async {
    final repo = _FakeRepo();
    await t.pumpWidget(host(repo, ValueNotifier(1)));
    await t.pump();
    await t.pumpWidget(const SizedBox());
    expect(repo.stopped, isTrue);
  });
}
