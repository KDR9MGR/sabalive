import 'package:flutter/material.dart' hide Text;

import '../../../theme/app_colors.dart';
import '../../../core/i18n/text.dart';

/// The two room-wide chat facts the host controls and everyone sees at once, both
/// carried on the live_streams row: the pinned notice, and when the chat was last
/// cleared. Feed it the row once on entry and again on every Realtime update.
class RoomChatState {
  String? notice;
  DateTime? clearedAt;

  /// Applies a live_streams row. Returns true when the host has just cleared the
  /// chat (so the caller drops the lines it holds). [initial] reads the row
  /// without that — a room joined after a clear starts empty anyway.
  bool apply(Map<String, dynamic> row, {bool initial = false}) {
    if (row.containsKey('pinned_notice')) {
      final n = (row['pinned_notice'] as String?)?.trim();
      notice = (n == null || n.isEmpty) ? null : n;
    }
    var cleared = false;
    final at = DateTime.tryParse('${row['chat_cleared_at'] ?? ''}');
    if (at != null && (clearedAt == null || at.isAfter(clearedAt!))) {
      cleared = !initial;
      clearedAt = at;
    }
    return cleared;
  }
}

/// The host's pinned notice, kept above the chat for the whole live.
class PinnedNoticeBanner extends StatelessWidget {
  const PinnedNoticeBanner(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 1),
            child: Icon(Icons.push_pin_rounded, size: 13, color: Colors.white),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontFamily: 'Poppins',
                fontSize: 11.5,
                color: Colors.white,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
