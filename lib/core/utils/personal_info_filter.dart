/// Hides phone numbers, e-mail addresses, UPI ids and messenger / social links
/// in chat text.
///
/// The server is the authority: a trigger on live chat and direct messages runs
/// the same patterns (see supabase/migrations/20261002120000_personal_info_filter.sql
/// — `mask_personal_info`), stores the original for the admin panel and hands
/// every other user the masked text. This copy exists so a sender's own
/// optimistic bubble shows the same text the server will store, instead of the
/// number flashing up and then being swapped out. Keep the two in step.
class PersonalInfoFilter {
  const PersonalInfoFilter._();

  static const mask = '***';

  static final _email = RegExp(
    r'[A-Za-z0-9._%+\-]+[\s]*(?:@|\(at\)|\[at\])[\s]*[A-Za-z0-9\-]+(?:[\s]*(?:\.|\(dot\)|\[dot\])[\s]*[A-Za-z0-9\-]+)+',
    caseSensitive: false,
  );
  static final _spokenEmail = RegExp(
    r'[A-Za-z0-9._\-]+[\s]+at[\s]+(?:gmail|yahoo|hotmail|outlook|icloud|proton|rediff)[\s]*(?:\.|[\s]dot[\s])[\s]*[A-Za-z]{2,}',
    caseSensitive: false,
  );
  static final _upi = RegExp(
    r'[A-Za-z0-9._\-]{2,}@(?:ok[a-z]+|ybl|ibl|axl|paytm|upi|apl|fbl|sbi|hdfcbank|icici|axisbank)',
    caseSensitive: false,
  );
  static final _link = RegExp(
    r'(?:https?://)?(?:www\.)?(?:wa\.me|t\.me|telegram\.(?:me|org)|instagram\.com|snapchat\.com|facebook\.com|fb\.com|fb\.me|m\.me|linkedin\.com|twitter\.com|x\.com|discord\.gg|chat\.whatsapp\.com)/[^\s]*',
    caseSensitive: false,
  );
  // 9+ digits, with spaces / dots / dashes / brackets (and emoji keycaps)
  // between them. Nine, not eight, so a date like 2026-10-02 is left alone.
  static final _phone = RegExp(
    r'\+?[0-9](?:[\s().\-\uFE0F\u20E3]{0,2}[0-9]){8,}[\uFE0F\u20E3]*',
  );
  static final _spokenPhone = RegExp(
    r'(?:(?:zero|one|two|three|four|five|six|seven|eight|nine|ek|do|teen|char|paanch|panch|chhe|chhah|saat|aath|nau)[\s,.\-]*){7,}',
    caseSensitive: false,
  );

  /// [text] with anything personal replaced by [mask], and which kinds were
  /// found (`email`, `upi`, `link`, `phone`).
  static ({String masked, List<String> kinds}) apply(String text) {
    var t = text;
    final kinds = <String>[];

    if (_email.hasMatch(t) || _spokenEmail.hasMatch(t)) {
      kinds.add('email');
      t = t.replaceAll(_email, mask).replaceAll(_spokenEmail, mask);
    }
    if (_upi.hasMatch(t)) {
      kinds.add('upi');
      t = t.replaceAll(_upi, mask);
    }
    if (_link.hasMatch(t)) {
      kinds.add('link');
      t = t.replaceAll(_link, mask);
    }
    if (_phone.hasMatch(t) || _spokenPhone.hasMatch(t)) {
      kinds.add('phone');
      t = t.replaceAll(_phone, mask).replaceAll(_spokenPhone, mask);
    }
    return (masked: t, kinds: kinds);
  }

  /// Just the masked text.
  static String maskText(String text) => apply(text).masked;
}
