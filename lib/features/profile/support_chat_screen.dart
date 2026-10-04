import 'dart:async';

import 'package:flutter/material.dart' hide Text;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../config/supabase_client.dart';
import '../../core/utils/errors.dart';
import '../../theme/app_colors.dart';
import '../../core/i18n/text.dart';

/// Chat with the Sabalive support team. One running conversation per user (the
/// support_threads / support_messages tables); the team answers from the admin
/// panel and you only ever see "Support", never which admin replied.
class SupportChatScreen extends StatefulWidget {
  const SupportChatScreen({super.key});

  @override
  State<SupportChatScreen> createState() => _SupportChatScreenState();
}

class _Msg {
  _Msg(this.id, this.body, this.fromStaff, this.at);
  final int id;
  final String body;
  final bool fromStaff;
  final DateTime at;
}

class _SupportChatScreenState extends State<SupportChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final List<_Msg> _messages = [];
  RealtimeChannel? _channel;
  bool _loading = true;
  bool _sending = false;
  String? _error;

  String get _me => supabase.auth.currentUser!.id;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _channel?.unsubscribe();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  _Msg _fromRow(Map<String, dynamic> r) => _Msg(
        r['id'] as int,
        r['body'] as String,
        r['from_staff'] as bool? ?? false,
        DateTime.tryParse('${r['created_at']}')?.toLocal() ?? DateTime.now(),
      );

  Future<void> _load() async {
    try {
      final rows = await supabase
          .from('support_messages')
          .select()
          .eq('thread_id', _me)
          .order('id', ascending: true)
          .limit(500);
      if (!mounted) return;
      setState(() {
        _messages
          ..clear()
          ..addAll([for (final r in rows) _fromRow(r)]);
        _loading = false;
        _error = null;
      });
      _markRead();
      _jumpToEnd();
      _channel = supabase
          .channel('support-$_me')
          .onPostgresChanges(
            event: PostgresChangeEvent.insert,
            schema: 'public',
            table: 'support_messages',
            filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'thread_id',
              value: _me,
            ),
            callback: (payload) {
              final m = _fromRow(payload.newRecord);
              if (!mounted || _messages.any((x) => x.id == m.id)) return;
              setState(() => _messages.add(m));
              if (m.fromStaff) _markRead();
              _jumpToEnd();
            },
          )
          .subscribe();
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = friendlyError(e);
        });
      }
    }
  }

  void _markRead() {
    unawaited(
      supabase.rpc('support_mark_read').then((_) {}, onError: (_) {}),
    );
  }

  void _jumpToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await supabase.rpc('support_send', params: {'p_body': text});
      _input.clear();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(friendlyError(e))));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  String _time(DateTime t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return '${t.day}/${t.month} $h:$m';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Support')),
      body: Column(
        children: [
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(_error!,
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: AppColors.textMuted)),
                        ),
                      )
                    : _messages.isEmpty
                        ? const Center(
                            child: Padding(
                              padding: EdgeInsets.all(32),
                              child: Text(
                                'Ask us anything — a problem, a payment, a question. '
                                'The support team replies here.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    color: AppColors.textMuted, height: 1.5),
                              ),
                            ),
                          )
                        : ListView.builder(
                            controller: _scroll,
                            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                            itemCount: _messages.length,
                            itemBuilder: (_, i) => _bubble(_messages[i]),
                          ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 4),
                      decoration: BoxDecoration(
                        color: AppColors.card,
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(color: AppColors.stroke),
                      ),
                      child: TextField(
                        controller: _input,
                        minLines: 1,
                        maxLines: 5,
                        maxLength: 2000,
                        textInputAction: TextInputAction.newline,
                        decoration: InputDecoration(
                          border: InputBorder.none,
                          counterText: '',
                          hintText: tr('Write to support…'),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: _send,
                    child: Container(
                      width: 46,
                      height: 46,
                      decoration: const BoxDecoration(
                        gradient: AppColors.primaryGradient,
                        shape: BoxShape.circle,
                      ),
                      child: _sending
                          ? const Padding(
                              padding: EdgeInsets.all(13),
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.send_rounded,
                              color: Colors.white, size: 20),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _bubble(_Msg m) {
    final mine = !m.fromStaff;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        constraints:
            BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: mine ? AppColors.primary : AppColors.card,
          borderRadius: BorderRadius.circular(16),
          border: mine ? null : Border.all(color: AppColors.stroke),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!mine)
              const Padding(
                padding: EdgeInsets.only(bottom: 2),
                child: Text('Support',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: AppColors.gold)),
              ),
            Text(m.body, style: const TextStyle(fontSize: 14, height: 1.35)),
            const SizedBox(height: 3),
            Text(_time(m.at),
                style: TextStyle(
                    fontSize: 10,
                    color: Colors.white.withValues(alpha: 0.6))),
          ],
        ),
      ),
    );
  }
}
