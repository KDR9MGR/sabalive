import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../theme/app_colors.dart';
import '../i18n/text.dart';

/// WhatsApp / Instagram / Copy Link sheet for sharing a piece of content
/// (currently just a live stream). [url] must be a real `https://` link (see
/// `liveShareUrl`): messengers only make those tappable, and opening one on a
/// device with the app jumps straight back into this same content (see
/// `DeepLinkService`).
Future<void> showShareSheet(
  BuildContext context, {
  required String title,
  required String url,
}) {
  final message = '$title\n$url';
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppColors.bgElevated,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Share',
                style: TextStyle(
                    fontFamily: 'Poppins', fontWeight: FontWeight.w700, fontSize: 16)),
            const SizedBox(height: 18),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _ShareOption(
                  icon: Icons.chat_bubble_rounded,
                  color: const Color(0xFF25D366),
                  label: 'WhatsApp',
                  onTap: () async {
                    Navigator.pop(sheetContext);
                    await launchUrl(
                      Uri.parse('https://wa.me/?text=${Uri.encodeComponent(message)}'),
                      mode: LaunchMode.externalApplication,
                    );
                  },
                ),
                _ShareOption(
                  icon: Icons.camera_alt_rounded,
                  color: const Color(0xFFE1306C),
                  label: 'Instagram',
                  onTap: () async {
                    Navigator.pop(sheetContext);
                    await Clipboard.setData(ClipboardData(text: message));
                    // Instagram has no public deep link for pre-filled text/link
                    // sharing (only Stories-with-media) — open the app and let
                    // the user paste the link that's now on their clipboard.
                    final opened = await launchUrl(
                      Uri.parse('instagram://app'),
                      mode: LaunchMode.externalApplication,
                    );
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text(opened
                            ? 'Link copied — paste it in Instagram'
                            : 'Instagram not installed — link copied instead'),
                      ));
                    }
                  },
                ),
                _ShareOption(
                  icon: Icons.link_rounded,
                  color: AppColors.primaryBright,
                  label: 'Copy Link',
                  onTap: () async {
                    Navigator.pop(sheetContext);
                    await Clipboard.setData(ClipboardData(text: url));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Link copied')),
                      );
                    }
                  },
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    ),
  );
}

class _ShareOption extends StatelessWidget {
  const _ShareOption({
    required this.icon,
    required this.color,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            child: Icon(icon, color: Colors.white, size: 26),
          ),
          const SizedBox(height: 8),
          Text(label, style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
        ],
      ),
    );
  }
}
