import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/widgets/app_avatar.dart';
import '../../core/widgets/pills.dart';
import '../../data/models.dart';
import '../../data/social_repository.dart';
import '../../router/app_nav.dart';
import '../../theme/app_colors.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _repo = SocialRepository();
  final _field = TextEditingController();
  Timer? _debounce;
  int _tab = 0; // 0 = People, 1 = Live
  int _seq = 0;
  bool _loading = false;
  String _q = '';
  List<AppUser> _people = const [];
  List<LiveStream> _streams = const [];

  @override
  void initState() {
    super.initState();
    _run(); // preload trending live
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _field.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    _q = v;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 280), _run);
  }

  Future<void> _run() async {
    final seq = ++_seq;
    setState(() => _loading = true);
    try {
      if (_tab == 0) {
        final r = await _repo.searchUsers(_q);
        if (seq != _seq || !mounted) return;
        setState(() => _people = r);
      } else {
        final r = await _repo.searchLiveStreams(_q);
        if (seq != _seq || !mounted) return;
        setState(() => _streams = r);
      }
    } catch (_) {
      // leave last results
    } finally {
      if (mounted && seq == _seq) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: TextField(
          controller: _field,
          autofocus: true,
          onChanged: _onChanged,
          decoration: const InputDecoration(
            hintText: 'Search people & live rooms',
            border: InputBorder.none,
          ),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
            child: SegmentedTabs(
              tabs: const ['People', 'Live'],
              index: _tab,
              onChanged: (i) {
                setState(() => _tab = i);
                _run();
              },
            ),
          ),
        ),
      ),
      body: _loading && _people.isEmpty && _streams.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : _tab == 0
              ? _peopleList()
              : _streamList(),
    );
  }

  Widget _peopleList() {
    if (_people.isEmpty) {
      return _empty(_q.isEmpty ? 'Search for people by name or @username' : 'No people found');
    }
    return ListView.builder(
      itemCount: _people.length,
      itemBuilder: (context, i) {
        final u = _people[i];
        return ListTile(
          onTap: () => AppNav.userProfile(context, u),
          leading: AppAvatar(name: u.name, size: 44),
          title: Text(u.name,
              style: const TextStyle(
                  fontFamily: 'Poppins', fontWeight: FontWeight.w600, fontSize: 14)),
          subtitle: Text(u.username,
              style: const TextStyle(fontSize: 11.5, color: AppColors.textMuted)),
          trailing: u.isLive
              ? const _LiveDot()
              : const Icon(Icons.chevron_right_rounded, color: AppColors.textMuted),
        );
      },
    );
  }

  Widget _streamList() {
    if (_streams.isEmpty) {
      return _empty(_q.isEmpty ? 'No live rooms right now' : 'No live rooms match');
    }
    return ListView.builder(
      itemCount: _streams.length,
      itemBuilder: (context, i) {
        final s = _streams[i];
        return ListTile(
          onTap: () => AppNav.watchLive(context, s),
          leading: AppAvatar(name: s.host.name, size: 44),
          title: Text(s.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontFamily: 'Poppins', fontWeight: FontWeight.w600, fontSize: 14)),
          subtitle: Text('${s.host.name} · ${s.category}',
              style: const TextStyle(fontSize: 11.5, color: AppColors.textMuted)),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.visibility_rounded,
                  size: 13, color: AppColors.textMuted),
              const SizedBox(width: 3),
              Text('${s.viewers}',
                  style:
                      const TextStyle(fontSize: 11.5, color: AppColors.textMuted)),
            ],
          ),
        );
      },
    );
  }

  Widget _empty(String text) => Center(
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Text(text,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.textMuted, fontSize: 13)),
        ),
      );
}

class _LiveDot extends StatelessWidget {
  const _LiveDot();
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: AppColors.danger,
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Text('LIVE',
            style: TextStyle(
                fontSize: 9, fontWeight: FontWeight.w700, color: Colors.white)),
      );
}
