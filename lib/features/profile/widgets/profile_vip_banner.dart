import 'package:flutter/material.dart' hide Text;

import '../../../core/i18n/text.dart';
import '../../../theme/app_colors.dart';

/// The gold "VIP · Luxury Privileges" strip on My Profile, between Edit Profile and the wallet.
///
/// It was taken off on 2026-10-26 because it only said "coming soon" when tapped; the owner asked for it back (2026-11-05), so it
/// is the same strip again, but now it leads somewhere real: [onTap] opens the VIP list (the VIP products the panel made; it opened the Store's Lucky ID tab until 2026-11-06).
class ProfileVipBanner extends StatelessWidget {
  const ProfileVipBanner({super.key, required this.onTap});

  final VoidCallback onTap;

  /// The plum used for the text and icons on the gold.
  static const ink = Color(0xFF3A1A5E);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 20),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          gradient: AppColors.goldGradient,
          borderRadius: BorderRadius.circular(16),
        ),
        child: const Row(
          children: [
            Icon(Icons.diamond_rounded, color: ink, size: 20),
            SizedBox(width: 10),
            Expanded(
              child: Text('VIP  ·  Luxury Privileges',
                  style: TextStyle(
                    fontFamily: 'Poppins',
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                    color: ink,
                  )),
            ),
            Icon(Icons.chevron_right_rounded, color: ink),
          ],
        ),
      ),
    );
  }
}
