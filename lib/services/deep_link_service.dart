import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';

import '../core/utils/share_links.dart';
import '../data/social_repository.dart';
import '../router/app_nav.dart';
import '../state/maintenance_controller.dart';

/// Handles live links from the Share sheet: `https://sabalive.in/live/<id>`
/// (what is shared now — a real link that messengers make tappable, opened
/// here by Android App Links or by the website's "Open in SABALIVE" button) and
/// the older `sabalive://live/<id>`. Kept entirely separate from
/// `com.sabalive.in://` (reserved for the Supabase OAuth callback) so the two
/// can never collide.
class DeepLinkService {
  DeepLinkService(this.navigatorKey);

  final GlobalKey<NavigatorState> navigatorKey;
  final _appLinks = AppLinks();

  Future<void> start() async {
    final initial = await _appLinks.getInitialLink();
    if (initial != null) _handle(initial);
    _appLinks.uriLinkStream.listen(_handle);
  }

  Future<void> _handle(Uri uri) async {
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
