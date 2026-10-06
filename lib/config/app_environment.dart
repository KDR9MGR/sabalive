import 'package:flutter/material.dart';

import 'supabase_config.dart';

/// Which backend a build talks to.
///
/// Every normal build (Play, App Store, `flutter run`) is **production**. A staging build exists only
/// when it is started with explicit flags (see docs/STAGING.md):
///
///   --dart-define=SABALIVE_ENV=staging
///   --dart-define=SUPABASE_URL=https://STAGING_REF.supabase.co
///   --dart-define=SUPABASE_PUBLISHABLE_KEY=STAGING_KEY
///
/// [validate] refuses to start a build whose name and backend disagree, so a staging build can never
/// quietly write to production, and a Play build can never ship pointing somewhere else.
class AppEnvironment {
  AppEnvironment._();

  static const String name = String.fromEnvironment('SABALIVE_ENV', defaultValue: 'production');

  static bool get isProduction => name == 'production';
  static bool get isStaging => !isProduction;

  /// Throws if [environment] and [url] do not belong together. Defaults check this build.
  static void validate({String environment = name, String url = SupabaseConfig.url}) {
    final atProduction = url == SupabaseConfig.productionUrl;
    if (environment == 'production' && !atProduction) {
      throw StateError(
        'A production build must use the production backend ($url is not it). '
        'Use --dart-define=SABALIVE_ENV=staging for a staging build.',
      );
    }
    if (environment != 'production' && atProduction) {
      throw StateError(
        'A "$environment" build must not use the production backend. '
        'Pass --dart-define=SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY for the $environment project.',
      );
    }
  }
}

/// A corner ribbon on every screen of a non-production build, so nobody mistakes it for the real app.
class EnvironmentRibbon extends StatelessWidget {
  const EnvironmentRibbon({super.key, required this.show, required this.child, this.label = 'STAGING'});

  final bool show;
  final Widget child;
  final String label;

  @override
  Widget build(BuildContext context) {
    if (!show) return child;
    return Banner(
      message: label.toUpperCase(),
      location: BannerLocation.bottomStart,
      color: const Color(0xFFD97706),
      child: child,
    );
  }
}
