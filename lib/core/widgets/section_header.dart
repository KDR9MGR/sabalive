import 'package:flutter/material.dart' hide Text;

import '../../theme/app_colors.dart';
import '../i18n/text.dart';

class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.actionLabel = 'See All',
    this.onAction,
    this.padding = const EdgeInsets.fromLTRB(20, 0, 20, 0),
  });

  final String title;
  final String actionLabel;
  final VoidCallback? onAction;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                fontFamily: 'Poppins',
                fontWeight: FontWeight.w600,
                fontSize: 16,
                color: AppColors.textPrimary,
              ),
            ),
          ),
          if (onAction != null)
            GestureDetector(
              onTap: onAction,
              child: Row(
                children: [
                  Text(
                    actionLabel,
                    style: TextStyle(
                      fontFamily: 'Poppins',
                      fontWeight: FontWeight.w600,
                      fontSize: 12.5,
                      color: AppColors.primaryBright,
                    ),
                  ),
                  Icon(Icons.chevron_right_rounded,
                      size: 16, color: AppColors.primaryBright),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
