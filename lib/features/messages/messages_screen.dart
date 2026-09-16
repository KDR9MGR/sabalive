import 'package:flutter/material.dart';

import '../../core/utils/errors.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/app_avatar.dart';
import '../../core/widgets/pills.dart';
import '../../data/messages_repository.dart';
import '../../data/models.dart';
import '../../router/app_nav.dart';
import '../../theme/app_colors.dart';

class MessagesScreen extends StatefulWidget {
  const MessagesScreen({super.key});

  @override
  State<MessagesScreen> createState() => _MessagesScreenState();
}

class _MessagesScreenState extends State<MessagesScreen> {
  final _repo = MessagesRepository();
  final _search = TextEditingController();

  int _tab = 0; // 0 = All, 1 = Requests
  bool _loading = true;
  String? _error;
  List<ConversationSummary> _all = const [];
  List<ConversationSummary> _requests = const [];
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([
        _repo.inbox(requests: false),
        _repo.inbox(requests: true),
      ]);
      if (!mounted) return;
      setState(() {
        _all = results[0];
        _requests = results[1];
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = friendlyError(e);
      });
    }
  }

  List<ConversationSummary> get _filteredAll {
    if (_query.isEmpty) return _all;
    final q = _query.toLowerCase();
    return _all
        .where((c) =>
            c.other.name.toLowerCase().contains(q) ||
            c.other.username.toLowerCase().contains(q))
        .toList();
  }

  Future<void> _openChat(ConversationSummary c) async {
    await AppNav.chat(context, c.other, conversationId: c.conversationId);
    if (mounted) _load();
  }

  Future<void> _accept(ConversationSummary c) async {
    try {
      await _repo.acceptRequest(c.conversationId);
      await _load();
    } catch (e) {
      _toast(friendlyError(e));
    }
  }

  Future<void> _decline(ConversationSummary c) async {
    try {
      await _repo.declineRequest(c.conversationId);
      await _load();
    } catch (e) {
      _toast(friendlyError(e));
    }
  }

  void _toast(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  Future<void> _composeMenu() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.bgElevated,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.person_add_alt_1_rounded),
              title: const Text('New message'),
              onTap: () => Navigator.pop(context, 'dm'),
            ),
            ListTile(
              leading: const Icon(Icons.groups_rounded),
              title: const Text('New group'),
              onTap: () => Navigator.pop(context, 'group'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == 'group') {
      await AppNav.newGroup(context);
      if (mounted) _load();
    } else {
      await _compose();
    }
  }

  Future<void> _compose() async {
    final picked = await showModalBottomSheet<AppUser>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.bgElevated,
      builder: (_) => _ComposeSheet(repo: _repo),
    );
    if (picked == null || !mounted) return;
    try {
      final id = await _repo.findOrCreateConversation(picked);
      if (!mounted) return;
      await AppNav.chat(context, picked, conversationId: id);
      if (mounted) _load();
    } catch (e) {
      _toast(friendlyError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 12, 6),
              child: Row(
                children: [
                  Text('Messages',
                      style: Theme.of(context).textTheme.headlineSmall),
                  const Spacer(),
                  IconButton(
                    onPressed: _composeMenu,
                    icon: const Icon(Icons.edit_square, size: 20),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: TextField(
                controller: _search,
                onChanged: (v) => setState(() => _query = v.trim()),
                decoration: InputDecoration(
                  hintText: 'Search messages',
                  prefixIcon: const Icon(Icons.search_rounded),
                  contentPadding: const EdgeInsets.symmetric(vertical: 0),
                  isDense: true,
                  constraints: const BoxConstraints(minHeight: 44),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: AppColors.stroke),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: SegmentedTabs(
                tabs: [
                  'All',
                  _requests.isEmpty ? 'Requests' : 'Requests (${_requests.length})',
                ],
                index: _tab,
                onChanged: (i) => setState(() => _tab = i),
              ),
            ),
            const SizedBox(height: 12),
            Expanded(child: _content()),
          ],
        ),
      ),
    );
  }

  Widget _content() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return _emptyState(_error!, retry: true);
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: _tab == 1 ? _requestsList() : _allList(),
    );
  }

  Widget _allList() {
    final rows = _filteredAll;
    final recent = _query.isEmpty ? _all.take(12).toList() : const <ConversationSummary>[];
    if (rows.isEmpty && recent.isEmpty) {
      return _emptyState(
        _query.isEmpty
            ? 'No conversations yet.\nTap the compose icon to start one.'
            : 'No matches for "$_query".',
      );
    }
    return ListView(
      padding: const EdgeInsets.only(bottom: 120),
      children: [
        if (recent.isNotEmpty) _recentStrip(recent),
        if (recent.isNotEmpty)
          const Divider(color: AppColors.stroke, height: 24),
        ...rows.map(_conversationTile),
      ],
    );
  }

  Widget _recentStrip(List<ConversationSummary> recent) {
    return SizedBox(
      height: 84,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        itemCount: recent.length,
        separatorBuilder: (_, _) => const SizedBox(width: 14),
        itemBuilder: (context, i) {
          final c = recent[i];
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _openChat(c),
            child: Column(
              children: [
                AppAvatar(name: c.other.name, size: 52),
                const SizedBox(height: 4),
                SizedBox(
                  width: 56,
                  child: Text(c.other.name.split(' ').first,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontSize: 10, color: AppColors.textSecondary)),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _conversationTile(ConversationSummary c) {
    return ListTile(
      onTap: () => _openChat(c),
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
      leading: AppAvatar(name: c.other.name, size: 48),
      title: Row(
        children: [
          Expanded(
            child: Text(c.other.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontFamily: 'Poppins',
                    fontWeight: FontWeight.w600,
                    fontSize: 14)),
          ),
          if (c.lastAt != null)
            Text(relativeTime(c.lastAt!),
                style: const TextStyle(
                    fontSize: 11, color: AppColors.textMuted)),
        ],
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Row(
          children: [
            Expanded(
              child: Text(
                  c.lastFromMe ? 'You: ${c.lastMessage}' : c.lastMessage,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 12.5,
                      color: c.unread
                          ? AppColors.textPrimary
                          : AppColors.textMuted)),
            ),
            if (c.unread)
              Container(
                margin: const EdgeInsets.only(left: 8),
                width: 9,
                height: 9,
                decoration: const BoxDecoration(
                  gradient: AppColors.primaryGradient,
                  shape: BoxShape.circle,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _requestsList() {
    if (_requests.isEmpty) {
      return _emptyState('No message requests.');
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 120),
      itemCount: _requests.length,
      itemBuilder: (context, i) {
        final c = _requests[i];
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              AppAvatar(name: c.other.name, size: 46),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(c.other.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontFamily: 'Poppins',
                            fontWeight: FontWeight.w600,
                            fontSize: 13.5)),
                    Text(c.lastMessage,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 12, color: AppColors.textMuted)),
                  ],
                ),
              ),
              _miniBtn('Accept', AppColors.primary, () => _accept(c)),
              const SizedBox(width: 6),
              _miniBtn('Delete', AppColors.surfaceAlt, () => _decline(c)),
            ],
          ),
        );
      },
    );
  }

  Widget _emptyState(String message, {bool retry = false}) {
    return ListView(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(40, 80, 40, 0),
          child: Column(
            children: [
              Icon(Icons.forum_outlined,
                  size: 44, color: AppColors.textMuted.withValues(alpha: 0.6)),
              const SizedBox(height: 12),
              Text(message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 13, color: AppColors.textMuted)),
              if (retry) ...[
                const SizedBox(height: 10),
                TextButton(onPressed: _load, child: const Text('Retry')),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _miniBtn(String label, Color color, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(label,
            style: const TextStyle(
                fontFamily: 'Poppins',
                fontWeight: FontWeight.w600,
                fontSize: 11,
                color: Colors.white)),
      ),
    );
  }
}

class _ComposeSheet extends StatefulWidget {
  const _ComposeSheet({required this.repo});
  final MessagesRepository repo;

  @override
  State<_ComposeSheet> createState() => _ComposeSheetState();
}

class _ComposeSheetState extends State<_ComposeSheet> {
  final _field = TextEditingController();
  List<AppUser> _results = const [];
  bool _searching = false;
  int _seq = 0;

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  Future<void> _run(String q) async {
    final seq = ++_seq;
    if (q.trim().isEmpty) {
      setState(() {
        _results = const [];
        _searching = false;
      });
      return;
    }
    setState(() => _searching = true);
    try {
      final users = await widget.repo.searchUsers(q);
      if (!mounted || seq != _seq) return;
      setState(() {
        _results = users;
        _searching = false;
      });
    } catch (_) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _results = const [];
        _searching = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            const Text('New Message',
                style: TextStyle(
                    fontFamily: 'Poppins',
                    fontWeight: FontWeight.w600,
                    fontSize: 15)),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
              child: TextField(
                controller: _field,
                autofocus: true,
                onChanged: _run,
                decoration: InputDecoration(
                  hintText: 'Search by name or @username',
                  prefixIcon: const Icon(Icons.search_rounded),
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: AppColors.stroke),
                  ),
                ),
              ),
            ),
            SizedBox(
              height: 320,
              child: _searching
                  ? const Center(child: CircularProgressIndicator())
                  : _results.isEmpty
                      ? const Center(
                          child: Text('Type to find people',
                              style: TextStyle(
                                  color: AppColors.textMuted, fontSize: 12.5)))
                      : ListView.builder(
                          itemCount: _results.length,
                          itemBuilder: (context, i) {
                            final u = _results[i];
                            return ListTile(
                              onTap: () => Navigator.pop(context, u),
                              leading: AppAvatar(name: u.name, size: 42),
                              title: Text(u.name,
                                  style: const TextStyle(
                                      fontFamily: 'Poppins',
                                      fontWeight: FontWeight.w600,
                                      fontSize: 13.5)),
                              subtitle: Text(u.username,
                                  style: const TextStyle(
                                      fontSize: 11.5,
                                      color: AppColors.textMuted)),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }
}
