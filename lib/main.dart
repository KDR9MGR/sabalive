import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'core/i18n/i18n.dart';
import 'config/app_environment.dart';
import 'config/supabase_config.dart';
import 'services/deep_link_service.dart';
import 'services/device_identity_service.dart';
import 'services/maintenance_http_client.dart';
import 'state/maintenance_controller.dart';
import 'state/remote_config_controller.dart';
import 'state/theme_config_controller.dart';
import 'theme/app_colors.dart';
import 'services/push_notifications_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // the language the user picked, so the very first frame is already in it
  await I18n.load();
  // the colours and font the panel last set, so the very first frame already wears them
  await ThemeConfigController.restore();
  SystemChrome.setSystemUIOverlayStyle(
    SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: AppColors.bg,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );
  // Every request carries this device's id, so the server can enforce device
  // bans (see the bans migration) without the app passing it call by call.
  final device = await DeviceIdentityService.instance.load();
  // Any API request the server turns away with MAINTENANCE_MODE locks the app at
  // once (see MaintenanceController); the client just passes the news along.
  final maintenance = MaintenanceController.instance;
  // refuses a build whose name and backend disagree (a staging build writing to production, or the reverse)
  AppEnvironment.validate();
  await Supabase.initialize(
    url: SupabaseConfig.url,
    publishableKey: SupabaseConfig.publishableKey,
    headers: {'x-device-id': device.id},
    httpClient: MaintenanceAwareClient(http.Client(), maintenance.reportRefused),
  );
  // Know whether the app is locked before the first screen shows — but never hold
  // the launch for more than a couple of seconds if the server is slow.
  await maintenance.start().timeout(const Duration(seconds: 2), onTimeout: () {});
  // Release controls (minimum app version, server-side switches). Never awaited: the launch must not
  // wait on it, and it fails open if the server cannot be reached.
  unawaited(RemoteConfigController.instance.start());
  await PushNotificationsService.instance.initializeApp();
  runApp(const SabaLiveApp());
  DeepLinkService(rootNavigatorKey).start();
  PushNotificationsService.instance.setupMessaging();
}
