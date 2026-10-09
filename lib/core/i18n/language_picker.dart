import 'package:flutter/material.dart' hide Text;

import '../../theme/app_colors.dart';
import 'app_language.dart';
import 'i18n.dart';
import 'text.dart';

/// Picks the app's language from a sheet; the whole app switches at once (see I18n).
/// Used by Settings and by the Language tile on the profile screen.
Future<void> showLanguagePicker(BuildContext context) async {
  final choice = await showModalBottomSheet<AppLanguage>(
    context: context,
    backgroundColor: AppColors.bgElevated,
    isScrollControlled: true,
    builder: (_) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 8, 20, 8),
            child: Text(
              'Choose a language',
              style: TextStyle(
                fontFamily: 'Poppins',
                fontWeight: FontWeight.w700,
                fontSize: 16,
              ),
            ),
          ),
          for (final l in kLanguages)
            ListTile(
              title: Text(l.nativeName),
              subtitle: Text(
                l.countryName == 'International'
                    ? l.englishName
                    : '${l.englishName} · ${l.countryName}',
                style: const TextStyle(
                  fontSize: 11.5,
                  color: AppColors.textMuted,
                ),
              ),
              trailing: l.code == I18n.current.code
                  ? Icon(
                      Icons.check_circle_rounded,
                      color: AppColors.primaryBright,
                    )
                  : null,
              onTap: () => Navigator.pop(context, l),
            ),
        ],
      ),
    ),
  );
  if (choice != null && choice.code != I18n.current.code) {
    await I18n.set(choice);
  }
}
