import 'package:flutter/material.dart' hide Text;

import '../../../theme/app_colors.dart';
import '../../../core/i18n/text.dart';

/// One tile in a [showToolGridSheet] — icon, label, tint color, action.
class ToolSpec {
  ToolSpec(this.icon, this.label, this.color, this.onTap);
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
}

/// The 4-column icon-tile grid bottom sheet, shared by the host's own Tools
/// sheet and the viewer's More sheet — same chrome (title, divider, tile
/// style) either side, just a different [tools] list. Previously the host
/// screen had this inline (private `_ToolSpec`/`_ToolTile`) while the
/// viewer screens used a plain `ListTile` list, so the two looked nothing
/// alike despite covering mostly the same actions.
Future<void> showToolGridSheet(
  BuildContext context, {
  required String title,
  required List<ToolSpec> tools,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.bgElevated,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
    ),
    builder: (_) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontFamily: 'Poppins',
                fontWeight: FontWeight.w700,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 12),
            Divider(color: AppColors.stroke, height: 1),
            const SizedBox(height: 16),
            GridView.count(
              crossAxisCount: 4,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 14,
              crossAxisSpacing: 12,
              childAspectRatio: 0.86,
              children: [
                for (final t in tools)
                  _ToolTile(
                    spec: t,
                    onTap: () {
                      Navigator.pop(context);
                      t.onTap();
                    },
                  ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

class _ToolTile extends StatelessWidget {
  const _ToolTile({required this.spec, required this.onTap});
  final ToolSpec spec;
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
            decoration: BoxDecoration(
              color: spec.color.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: spec.color.withValues(alpha: 0.35)),
            ),
            child: Icon(spec.icon, color: spec.color, size: 26),
          ),
          const SizedBox(height: 6),
          Text(
            spec.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 10.5,
              color: AppColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}
