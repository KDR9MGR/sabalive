import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/utils/auth_links.dart';
import '../core/utils/share_links.dart';
import '../data/social_repository.dart';
import '../router/app_nav.dart';
import '../state/maintenance_controller.dart';

/// Handles live links from the Share sheet: `https://sabalive.in/live/<id>`
/// (what is shared now — a real link that messengers make tappable, opened
/// here by Android App Links or by the website's "Open in SABALIVE" button) and
/// the older `sabalive://live/<id>`. Kept entirely separate from
/// `com.sabalive.in://` (reserved for the Supabase OAuth callback) so the two
/// can never collide. The one thing it does with that callback is close the
/// sign-in browser (see [_closeSignInBrowser]); supabase_flutter reads the link itself.
class DeepLinkService {
  DeepLinkService(this.navigatorKey, {Future<void> Function()? closeSignInBrowser})
    : _closeSignInBrowser = closeSignInBrowser ?? _closeInAppBrowser;

  final GlobalKey<NavigatorState> navigatorKey;
  final _appLinks = AppLinks();
  final Future<void> Function() _closeSignInBrowser;

  /// An Apple / Facebook sign-in runs in a browser sheet over the app (SFSafariViewController
  /// on iOS). When it ends, Supabase sends it to `com.sabalive.in://login-callback/...`, which
  /// reopens the app and signs the user in, but nothing closes that sheet, so the user is left
  /// looking at the browser. Android opens a separate browser app and is left as it was.
  static Future<void> _closeInAppBrowser() async {
    if (defaultTargetPlatform != TargetPlatform.iOS) return;
    try {
      await closeInAppWebView();
    } catch (_) {
      // nothing open, or not closable: the sign-in itself is not affected
    }
  }

  Future<void> start() async {
    final initial = await _appLinks.getInitialLink();
    if (initial != null) _handle(initial);
    _appLinks.uriLinkStream.listen(_handle);
  }

  @visibleForTesting
  Future<void> handle(Uri uri) => _handle(uri);

  Future<void> _handle(Uri uri) async {
    if (isAuthCallbackUri(uri)) {
      await _closeSignInBrowser();
      return;
    }
    final id = liveIdFromUri(uri);
    if (id == null) return;
    // locked for maintenance: the maintenance screen stays; the link is dropped
    if (MaintenanceController.instance.locked) return;
    final stream = await SocialRepository().streamById(id);
    // Freshly read after the await, not held across it — this isn't a
    // widget's own State.context (no `mounted` to check), it's the
    // navigator's current context read right before use.
    final context = navigatorKey.currentContext;
    if (stream == null || context == null) return;
    // ignore: use_build_context_synchronously
    await AppNav.watchLive(context, stream);
  }
}
