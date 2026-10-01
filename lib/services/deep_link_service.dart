import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';

import '../data/social_repository.dart';
import '../router/app_nav.dart';

/// Handles `sabalive://live/<streamId>` links from the Share sheet — a
/// scheme kept entirely separate from `com.sabalive.in://` (reserved for
/// the Supabase OAuth callback) so the two can never collide.
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
    if (uri.scheme != 'sabalive' || uri.host != 'live') return;
    final id = uri.pathSegments.isNotEmpty ? uri.pathSegments.first : null;
    if (id == null) return;
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
