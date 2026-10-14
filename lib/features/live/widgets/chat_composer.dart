import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart';

import '../../../core/widgets/app_avatar.dart';
import '../../../data/models.dart';
import '../../../theme/app_colors.dart';
import '../../../core/i18n/text.dart';
import 'mentions.dart';

/// The chat input shared by the host's screen and the audio and video viewer screens:
///  - at most [kLiveChatMaxChars] characters, with a small counter near the end;
///  - typing "@" lists people in the room; picking one tags them (see mentions.dart);
///  - a person whose chat the host turned off sees why and cannot type.
///
/// It lays out as: tag suggestions (only while typing an @), then a row of [leading] buttons, the input pill and the
/// send button. [onSend] reads the text from [controller] (and clears it), as each screen's own send already did.
class LiveChatComposer extends StatefulWidget {
  const LiveChatComposer({
    super.key,
    required this.controller,
    required this.onSend,
    required this.leading,
    required this.people,
    this.myId,
    this.focusNode,
    this.chatOff = false,
    this.hint = 'Say something nice…',
  });

  final TextEditingController controller;
  final VoidCallback onSend;

  /// The round buttons to the left of the pill (More, Emoji, Gift).
  final List<Widget> leading;

  /// Who can be tagged right now: the host, people on a seat, recent chatters. Read when "@" is typed.
  final List<AppUser> Function() people;
  final String? myId;
  final FocusNode? focusNode;

  /// The host turned this person's chat off for the live.
  final bool chatOff;
  final String hint;

  @override
  State<LiveChatComposer> createState() => _LiveChatComposerState();
}

class _LiveChatComposerState extends State<LiveChatComposer> {
  List<AppUser> _suggestions = const [];

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChanged);
  }

  @override
  void didUpdateWidget(LiveChatComposer old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_onChanged);
      widget.controller.addListener(_onChanged);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    final value = widget.controller.value;
    final cursor = value.selection.isValid ? value.selection.baseOffset : value.text.length;
    final m = activeMention(value.text, cursor);
    final next = m == null
        ? const <AppUser>[]
        : mentionCandidates(m.query, widget.people(), excludeId: widget.myId);
    if (!_sameList(next, _suggestions) && mounted) setState(() => _suggestions = next);
  }

  static bool _sameList(List<AppUser> a, List<AppUser> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id) return false;
    }
    return true;
  }

  void _pick(AppUser user) {
    final value = widget.controller.value;
    final cursor = value.selection.isValid ? value.selection.baseOffset : value.text.length;
    final r = insertMention(value.text, cursor, user.name);
    if (r == null) return;
    widget.controller.value = TextEditingValue(
      text: r.text,
      selection: TextSelection.collapsed(offset: r.cursor),
    );
    widget.focusNode?.requestFocus();
  }

  /// Sends what is typed and puts the keyboard away, so the live is back in full view after each message. The keyboard's own
  /// send key and the round send button both come here. An empty box is left alone (nothing was sent, so the keyboard stays).
  void _submit() {
    final hadText = widget.controller.text.trim().isNotEmpty;
    widget.onSend();
    if (hadText) (widget.focusNode ?? FocusManager.instance.primaryFocus)?.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_suggestions.isNotEmpty) _suggestionList(),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final w in widget.leading) ...[w, const SizedBox(width: 6)],
              Expanded(child: _pill()),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: widget.chatOff ? null : _submit,
                child: Opacity(
                  opacity: widget.chatOff ? 0.4 : 1,
                  child: Container(
                    width: 42,
                    height: 42,
                    decoration: const BoxDecoration(gradient: AppColors.liveGradient, shape: BoxShape.circle),
                    child: const Icon(Icons.send_rounded, color: Colors.white, size: 19),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _pill() {
    return Container(
      constraints: const BoxConstraints(minHeight: 42),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.42),
        borderRadius: BorderRadius.circular(21),
        border: Border.all(color: Colors.white24),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: widget.controller,
              focusNode: widget.focusNode,
              enabled: !widget.chatOff,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              cursorColor: AppColors.primaryBright,
              maxLines: 1,
              keyboardType: TextInputType.text,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _submit(),
              inputFormatters: [LengthLimitingTextInputFormatter(kLiveChatMaxChars)],
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                counterText: '',
                hintText: widget.chatOff ? tr('The host turned your chat off') : tr(widget.hint),
                hintMaxLines: 1,
                hintStyle: const TextStyle(color: Colors.white54, fontSize: 13, overflow: TextOverflow.ellipsis),
              ),
            ),
          ),
          // a small count once the message is getting long
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: widget.controller,
            builder: (_, v, _) => v.text.length >= 45
                ? Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Text(
                      '${v.text.length}/$kLiveChatMaxChars',
                      style: TextStyle(
                        fontSize: 10.5,
                        color: v.text.length >= kLiveChatMaxChars ? AppColors.danger : Colors.white54,
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  Widget _suggestionList() {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white24),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final u in _suggestions)
            InkWell(
              onTap: () => _pick(u),
              borderRadius: BorderRadius.circular(14),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                child: Row(
                  children: [
                    AppAvatar(name: u.name, imageUrl: u.avatarUrl, size: 28),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        u.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
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
}
