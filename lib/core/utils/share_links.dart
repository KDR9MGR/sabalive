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
