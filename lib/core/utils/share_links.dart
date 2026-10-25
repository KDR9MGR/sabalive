import 'ids.dart';

/// The website that share links point at. A plain `https://` link is what
/// WhatsApp, SMS and the rest recognise as a link and make tappable; the
/// app's own `sabalive://` scheme is shown as plain text there.
const shareHost = 'sabalive.in';

/// The link shared for a live stream: `https://sabalive.in/live/<streamId>`.
///
/// On a phone with the app, Android opens it straight in the app (App Links,
/// see AndroidManifest.xml and the site's assetlinks.json); anywhere else the
/// page it lands on offers "Open in SABALIVE" and tries to open the app itself.
String liveShareUrl(String streamId) => 'https://$shareHost/live/$streamId';

/// The app's id on Google Play.
const playPackageId = 'com.sabalive.in';

/// The link a person shares to invite a friend: the app's Google Play page, opened straight in the Play Store on an Android phone (WhatsApp, SMS and the
/// rest hand `play.google.com` links to the Play Store app). It used to point at `sabalive.app/invite/<code>`, a page that does not exist, so the link did
/// nothing. The invite code rides along as the Play "referrer" (`utm_source=invite`, `utm_content=<code>`): Play keeps it with the install, so the app can
/// read it on first launch later without the link changing. Until then the friend types the code (it is also written in the share text).
String inviteShareUrl(String code) {
  final clean = code.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '');
  final referrer = Uri.encodeQueryComponent('utm_source=invite&utm_medium=referral${clean.isEmpty ? '' : '&utm_content=$clean'}');
  return 'https://play.google.com/store/apps/details?id=$playPackageId&referrer=$referrer';
}

/// The message that goes out with the invite link.
String inviteShareText(String code) => 'Join me on SABALIVE! Use my invite code $code. ${inviteShareUrl(code)}';

/// The stream id inside a live link, or null if [uri] isn't one. Understands
/// both the shared https link and the older `sabalive://live/<id>` form.
String? liveIdFromUri(Uri uri) {
  final List<String> segments;
  if (uri.scheme == 'sabalive' && uri.host == 'live') {
    segments = uri.pathSegments;
  } else if ((uri.scheme == 'https' || uri.scheme == 'http') &&
      (uri.host == shareHost || uri.host == 'www.$shareHost') &&
      uri.pathSegments.isNotEmpty &&
      uri.pathSegments.first == 'live') {
    segments = uri.pathSegments.skip(1).toList();
  } else {
    return null;
  }
  if (segments.isEmpty) return null;
  final id = segments.first;
  return isRealId(id) ? id : null;
}
