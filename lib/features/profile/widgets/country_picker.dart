import 'package:flutter/material.dart' hide Text;

import '../../../core/i18n/text.dart';
import '../../../data/countries.dart';
import '../../../data/models.dart';
import '../../../theme/app_colors.dart';

/// Opens the searchable country list; completes with the English name that was tapped (null when the sheet is closed). Each country is shown with its flag.
/// Used by the "Complete your profile" step and by Edit Profile, so there is ONE list and a saved country always has a flag.
Future<String?> showCountrySheet(BuildContext context, {String? selected}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
    builder: (_) => CountrySheet(selected: selected),
  );
}

/// The flag a PROFILE shows: the one of the country the person chose, or null.
///
/// Only somebody who has been through the "Complete your profile" step has chosen a country: every account starts with "India" (a database default), so without
/// that check a person who never picked one would wear an Indian flag. The saved date of birth is the same signal the app already uses for that step
/// (`needsProfileCompletion`). A text that is not one of the listed countries (a city typed in the old free-text field) has no flag.
String? flagOfUser(AppUser user) => user.dateOfBirth == null ? null : flagOfCountry(user.location);

/// A small flag next to a name; nothing at all when [flag] is null, so a profile never jumps.
class CountryFlag extends StatelessWidget {
  const CountryFlag(this.flag, {super.key, this.size = 18});

  final String? flag;
  final double size;

  @override
  Widget build(BuildContext context) {
    final f = flag;
    if (f == null) return const SizedBox.shrink();
    // the flag is a picture-like glyph: no text scaling, no line-height padding
    return Text(f, key: const ValueKey('country-flag'), textScaler: TextScaler.noScaling, style: TextStyle(fontSize: size, height: 1));
  }
}

/// The searchable country list; pops with the English name that was tapped.
class CountrySheet extends StatefulWidget {
  const CountrySheet({super.key, required this.selected});
  final String? selected;

  @override
  State<CountrySheet> createState() => _CountrySheetState();
}

class _CountrySheetState extends State<CountrySheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final found = searchCountries(_query);
    final height = MediaQuery.of(context).size.height * 0.8;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SizedBox(
        height: height,
        child: Column(
          children: [
            const SizedBox(height: 10),
            Container(width: 40, height: 4, decoration: BoxDecoration(color: AppColors.stroke, borderRadius: BorderRadius.circular(2))),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: TextField(
                key: const ValueKey('country-search'),
                autofocus: false,
                onChanged: (v) => setState(() => _query = v),
                decoration: InputDecoration(prefixIcon: const Icon(Icons.search_rounded), hintText: tr('Search country')),
              ),
            ),
            Expanded(
              child: found.isEmpty
                  ? const Center(child: Text('No country found', style: TextStyle(color: AppColors.textMuted)))
                  : ListView.builder(
                      itemCount: found.length,
                      itemBuilder: (context, i) {
                        final c = found[i];
                        return ListTile(
                          key: ValueKey('country-$c'),
                          dense: true,
                          leading: SizedBox(width: 30, child: Center(child: CountryFlag(flagOfCountry(c), size: 22))),
                          title: Text(c),
                          trailing: c == widget.selected ? const Icon(Icons.check_rounded, color: AppColors.success) : null,
                          onTap: () => Navigator.of(context).pop(c),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
