import '../../../data/models.dart';

/// Tagging someone in live chat: "@" then a name picked from the room.
///
/// A mention is written `@` + the person's display name with every space turned into a no-break space, so it stays
/// one word to the parser ("@Astro Sharma") while looking exactly like the name on screen. Nothing is stored
/// besides the chat text itself.

/// The longest a live chat message may be.
const int kLiveChatMaxChars = 60;

const String _nbsp = ' ';

/// "@" + [name] as one word.
String mentionToken(String name) => '@${name.trim().replaceAll(' ', _nbsp)}';

/// A name as the chat parser sees it: no-break spaces are spaces, case ignored.
String _norm(String s) => s.replaceAll(_nbsp, ' ').trim().toLowerCase();

/// The "@..." the cursor is in the middle of typing: where it starts and what has been typed after the "@".
/// Null when the cursor is not inside one.
({int start, String query})? activeMention(String text, int cursor) {
  if (cursor < 1 || cursor > text.length) return null;
  final before = text.substring(0, cursor);
  final at = before.lastIndexOf('@');
  if (at < 0) return null;
  // the @ must start a word, and nothing typed after it may be a plain space or a new line
  if (at > 0 && before[at - 1] != ' ' && before[at - 1] != '\n') return null;
  final query = before.substring(at + 1);
  if (query.contains(' ') || query.contains('\n')) return null;
  return (start: at, query: query);
}

/// The people whose name fits [query], names starting with it first, at most [limit]. [query] may hold no-break
/// spaces (a name typed with its spaces glued). [excludeId] (yourself) never appears.
List<AppUser> mentionCandidates(
  String query,
  Iterable<AppUser> people, {
  String? excludeId,
  int limit = 5,
}) {
  final q = _norm(query);
  final seen = <String>{};
  final starts = <AppUser>[];
  final contains = <AppUser>[];
  for (final p in people) {
    if (p.id == excludeId || !seen.add(p.id)) continue;
    final n = _norm(p.name);
    if (n.isEmpty) continue;
    if (n.startsWith(q)) {
      starts.add(p);
    } else if (q.isNotEmpty && n.contains(q)) {
      contains.add(p);
    }
  }
  return [...starts, ...contains].take(limit).toList();
}

/// [text] with the "@query" under the cursor replaced by the finished mention and a space, and where the cursor
/// goes next. Null when the cursor is not in a mention or the result would be longer than [maxChars].
({String text, int cursor})? insertMention(String text, int cursor, String name, {int maxChars = kLiveChatMaxChars}) {
  final m = activeMention(text, cursor);
  if (m == null) return null;
  final token = '${mentionToken(name)} ';
  final next = text.substring(0, m.start) + token + text.substring(cursor);
  if (next.length > maxChars) return null;
  return (text: next, cursor: m.start + token.length);
}

/// A run of chat text: either ordinary words or one "@name".
class MentionPart {
  const MentionPart(this.text, this.isMention);
  final String text;
  final bool isMention;
}

final RegExp _mention = RegExp(r'(^|(?<=[ \n]))@[^ \n]+');

/// [text] cut into ordinary runs and mentions, in order, so the chat can colour the mentions.
List<MentionPart> parseMentions(String text) {
  final parts = <MentionPart>[];
  var last = 0;
  for (final m in _mention.allMatches(text)) {
    if (m.start > last) parts.add(MentionPart(text.substring(last, m.start), false));
    parts.add(MentionPart(m.group(0)!, true));
    last = m.end;
  }
  if (last < text.length) parts.add(MentionPart(text.substring(last), false));
  return parts;
}

/// Whether [text] tags [name] (the viewer's own name, to mark the line as for them).
bool mentionsName(String text, String name) {
  final want = _norm(name);
  if (want.isEmpty) return false;
  for (final p in parseMentions(text)) {
    if (p.isMention && _norm(p.text.substring(1)) == want) return true;
  }
  return false;
}
