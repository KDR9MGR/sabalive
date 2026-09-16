import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/utils/errors.dart';
import '../../core/widgets/app_avatar.dart';
import '../../data/calls_repository.dart';
import '../../data/messages_repository.dart';
import '../../data/models.dart';
import '../../router/app_nav.dart';
import '../../theme/app_colors.dart';
import '../calls/call_screen.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.user,
    required this.conversationId,
  });

  final AppUser user;
  final String conversationId;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _repo = MessagesRepository();
  final _controller = TextEditingController();
  final _scroll = ScrollController();

  final _messages = <Bubble>[];
  final _pendingOutgoing = <String>[]; // bodies we optimistically appended
  RealtimeChannel? _channel;
  bool _loading = true;
  bool _sending = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
    _channel = _repo.subscribeMessages(widget.conversationId, _onRealtime);
  }

  @override
  void dispose() {
    _controller.dispose();
    _scroll.dispose();
    final channel = _channel;
    if (channel != null) Supabase.instance.client.removeChannel(channel);
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final history = await _repo.messages(widget.conversationId);
      if (!mounted) return;
      setState(() {
        _messages
          ..clear()
          ..addAll(history);
        _loading = false;
        _error = null;
      });
      _jumpToBottom();
      unawaited(_repo.markRead(widget.conversationId));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = friendlyError(e);
      });
    }
  }

  void _onRealtime(Bubble bubble) {
    if (!mounted) return;
    // Drop the echo of a message we already appended optimistically.
    if (bubble.fromMe) {
      final i = _pendingOutgoing.indexOf(bubble.text);
      if (i != -1) {
        _pendingOutgoing.removeAt(i);
        return;
      }
    }
    // Group realtime rows don't carry the sender's name — reload to fill it in.
    if (_isGroup && !bubble.fromMe && bubble.senderName.isEmpty) {
      unawaited(_load());
      return;
    }
    setState(() => _messages.add(bubble));
    _jumpToBottom();
    if (!bubble.fromMe) unawaited(_repo.markRead(widget.conversationId));
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _sending) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _sending = true;
      _messages.add(Bubble(text, true, time: _now()));
      _pendingOutgoing.add(text);
      _controller.clear();
    });
    _jumpToBottom();
    try {
      await _repo.send(widget.conversationId, text);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _messages.removeLast();
        _pendingOutgoing.remove(text);
        _controller.text = text;
      });
      messenger.showSnackBar(SnackBar(content: Text(friendlyError(e))));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  String _now() {
    final d = DateTime.now();
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  bool get _isGroup => widget.user.username == '@group';

  Future<void> _startCall(CallKind kind) async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      final call = await CallsRepository().startCall(widget.user, kind: kind);
      await navigator.push(MaterialPageRoute(
        builder: (_) => CallScreen(call: call, outgoing: true),
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(friendlyError(e))));
    }
  }

  void _jumpToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: GestureDetector(
          onTap: widget.user.username == '@group'
              ? null
              : () => AppNav.userProfile(context, widget.user),
          child: Row(
            children: [
              AppAvatar(name: widget.user.name, size: 36),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.user.name,
                      style: const TextStyle(
                          fontFamily: 'Poppins',
                          fontWeight: FontWeight.w600,
                          fontSize: 15)),
                  Text(widget.user.username == '@group' ? 'Group' : widget.user.username,
                      style: const TextStyle(
                          fontSize: 11, color: AppColors.textMuted)),
                ],
              ),
            ],
          ),
        ),
        actions: [
          if (!_isGroup) ...[
            IconButton(
                onPressed: () => _startCall(CallKind.audio),
                icon: const Icon(Icons.call_rounded)),
            IconButton(
                onPressed: () => _startCall(CallKind.video),
                icon: const Icon(Icons.videocam_rounded)),
          ],
          IconButton(
              onPressed: () {}, icon: const Icon(Icons.more_vert_rounded)),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: _body()),
          _inputBar(),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return _centered(_error!, action: _load);
    }
    if (_messages.isEmpty) {
      return _centered('No messages yet. Say hello 👋');
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      itemCount: _messages.length + 1,
      itemBuilder: (context, i) {
        if (i == 0) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text('Today',
                  style: TextStyle(fontSize: 11, color: AppColors.textMuted)),
            ),
          );
        }
        return _bubble(_messages[i - 1]);
      },
    );
  }

  Widget _centered(String text, {VoidCallback? action}) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(text,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.textMuted, fontSize: 13)),
          if (action != null) ...[
            const SizedBox(height: 10),
            TextButton(onPressed: action, child: const Text('Retry')),
          ],
        ],
      ),
    );
  }

  Widget _bubble(Bubble b) {
    final mine = b.fromMe;
    if (b.kind == BubbleKind.gift) {
      return Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 6),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            gradient: AppColors.goldGradient,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('🎁', style: TextStyle(fontSize: 18)),
              const SizedBox(width: 8),
              Text(b.text,
                  style: const TextStyle(
                      fontFamily: 'Poppins',
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                      color: Color(0xFF3A1A5E))),
            ],
          ),
        ),
      );
    }

    if (b.kind == BubbleKind.sticker) {
      return Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Text(b.text, style: const TextStyle(fontSize: 46)),
        ),
      );
    }

    final showSender = _isGroup && !mine && b.senderName.isNotEmpty;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Column(
        crossAxisAlignment:
            mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          if (showSender)
            Padding(
              padding: const EdgeInsets.only(left: 6, top: 4),
              child: Text(b.senderName,
                  style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: AppColors.primaryBright)),
            ),
          Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.72),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          gradient: mine ? AppColors.primaryGradient : null,
          color: mine ? null : AppColors.surface,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(18),
            topRight: const Radius.circular(18),
            bottomLeft: Radius.circular(mine ? 18 : 4),
            bottomRight: Radius.circular(mine ? 4 : 18),
          ),
          border: mine ? null : Border.all(color: AppColors.stroke),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(b.text,
                style: TextStyle(
                    fontSize: 13.5,
                    height: 1.35,
                    color: mine ? Colors.white : AppColors.textPrimary)),
            if (b.time.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(b.time,
                  style: TextStyle(
                      fontSize: 9,
                      color: mine ? Colors.white70 : AppColors.textMuted)),
            ],
          ],
        ),
          ),
        ],
      ),
    );
  }

  Widget _inputBar() {
    return Container(
      padding: EdgeInsets.fromLTRB(
          12, 8, 12, 8 + MediaQuery.of(context).padding.bottom),
      decoration: const BoxDecoration(
        color: AppColors.bgElevated,
        border: Border(top: BorderSide(color: AppColors.stroke)),
      ),
      child: Row(
        children: [
          const Icon(Icons.add_circle_outline_rounded,
              color: AppColors.primaryBright),
          const SizedBox(width: 10),
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: AppColors.stroke),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      style: const TextStyle(fontSize: 13.5),
                      textInputAction: TextInputAction.send,
                      decoration: const InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        hintText: 'Type a message…',
                      ),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  const Icon(Icons.emoji_emotions_outlined,
                      color: AppColors.textMuted, size: 20),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: _send,
            child: Container(
              width: 42,
              height: 42,
              decoration: const BoxDecoration(
                gradient: AppColors.primaryGradient,
                shape: BoxShape.circle,
              ),
              child: _sending
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.send_rounded,
                      color: Colors.white, size: 20),
            ),
          ),
        ],
      ),
    );
  }
}
