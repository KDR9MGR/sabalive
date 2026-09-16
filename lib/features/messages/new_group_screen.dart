import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/utils/errors.dart';
import '../../core/widgets/app_avatar.dart';
import '../../core/widgets/gradient_button.dart';
import '../../data/messages_repository.dart';
import '../../data/models.dart';
import '../../router/app_nav.dart';
import '../../theme/app_colors.dart';

class NewGroupScreen extends StatefulWidget {
  const NewGroupScreen({super.key});

  @override
  State<NewGroupScreen> createState() => _NewGroupScreenState();
}

class _NewGroupScreenState extends State<NewGroupScreen> {
  final _repo = MessagesRepository();
  final _name = TextEditingController();
  final _search = TextEditingController();
  Timer? _debounce;
  int _seq = 0;
  bool _searching = false;
  bool _creating = false;
  List<AppUser> _results = const [];
  final Map<String, AppUser> _picked = {};

  @override
  void dispose() {
    _debounce?.cancel();
    _name.dispose();
    _search.dispose();
    super.dispose();
  }

  void _onSearch(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 280), () => _run(v));
  }

  Future<void> _run(String q) async {
    final seq = ++_seq;
    if (q.trim().isEmpty) {
      setState(() => _results = const []);
      return;
    }
    setState(() => _searching = true);
    try {
      final r = await _repo.searchUsers(q);
      if (seq != _seq || !mounted) return;
      setState(() => _results = r);
    } catch (_) {
    } finally {
      if (mounted && seq == _seq) setState(() => _searching = false);
    }
  }

  Future<void> _create() async {
    if (_picked.isEmpty || _creating) return;
    setState(() => _creating = true);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      final id = await _repo.startGroup(_name.text.trim(), _picked.keys.toList());
      if (!mounted) return;
      final groupUser = AppUser(
        id: id,
        name: _name.text.trim().isEmpty ? 'Group' : _name.text.trim(),
        username: '@group',
      );
      navigator.pop();
      await AppNav.chat(context, groupUser, conversationId: id);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(friendlyError(e))));
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('New Group')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 6),
            child: TextField(
              controller: _name,
              decoration: const InputDecoration(hintText: 'Group name (optional)'),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 6, 20, 6),
            child: TextField(
              controller: _search,
              onChanged: _onSearch,
              decoration: const InputDecoration(
                hintText: 'Add people',
                prefixIcon: Icon(Icons.search_rounded),
              ),
            ),
          ),
          if (_picked.isNotEmpty)
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                children: [
                  for (final u in _picked.values)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Chip(
                        label: Text(u.name.split(' ').first),
                        onDeleted: () => setState(() => _picked.remove(u.id)),
                      ),
                    ),
                ],
              ),
            ),
          Expanded(
            child: _searching
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    itemCount: _results.length,
                    itemBuilder: (context, i) {
                      final u = _results[i];
                      final sel = _picked.containsKey(u.id);
                      return CheckboxListTile(
                        value: sel,
                        onChanged: (_) => setState(() {
                          if (sel) {
                            _picked.remove(u.id);
                          } else {
                            _picked[u.id] = u;
                          }
                        }),
                        secondary: AppAvatar(name: u.name, size: 40),
                        title: Text(u.name,
                            style: const TextStyle(
                                fontFamily: 'Poppins',
                                fontWeight: FontWeight.w600,
                                fontSize: 13.5)),
                        subtitle: Text(u.username,
                            style: const TextStyle(
                                fontSize: 11.5, color: AppColors.textMuted)),
                      );
                    },
                  ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
                20, 8, 20, 12 + MediaQuery.of(context).padding.bottom),
            child: GradientButton(
              label: _picked.isEmpty
                  ? 'Add people to create'
                  : 'Create group (${_picked.length})',
              loading: _creating,
              onPressed: _picked.isEmpty ? null : _create,
            ),
          ),
        ],
      ),
    );
  }
}
