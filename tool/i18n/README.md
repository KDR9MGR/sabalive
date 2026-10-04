# Translations

The app shows text in 9 languages (Hindi, English, Bangla, Nepali, Urdu/Pakistan,
Arabic/Egypt, Nigerian English, Filipino, Portuguese/Brazil). English in the code is the key.

- `keys.json` — every English string that has a translation (index = line number in the `tr_*.tsv`).
- `tr_<lang>.tsv` — `index<TAB>translation`. `{0}`, `{1}` are live values; `\n` is a line break.
  Nigerian English uses the English text, so it has no file.
- `gen.py` — writes `lib/core/i18n/strings_<lang>.dart` from the two above:
  `python3 tool/i18n/gen.py`. Never edit the generated Dart files by hand.
- `missing.py` — lists strings in `lib/` that look like UI text but aren't in `keys.json` yet:
  `python3 tool/i18n/missing.py` (some are code, ignore those).

## Adding or changing a string
1. Write the English in the code as usual (`Text('Hello')`; `tr('...')` for a hint / tooltip).
2. Append it to the end of `keys.json` (new index = old length) and add a line to every `tr_*.tsv`.
   Changing English text changes its key, so update `keys.json` too.
3. `python3 tool/i18n/gen.py`.

Anything without a translation simply shows in English. Text that comes from the database
(host titles, category names, gift names) is not translated.

The translations were written by Claude and should be reviewed by native speakers.
