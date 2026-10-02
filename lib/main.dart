import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'config/supabase_config.dart';
import 'services/deep_link_service.dart';
import 'services/device_identity_service.dart';
import 'services/push_notifications_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Color(0xFF0B0716),
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );
  // Every request carries this device's id, so the server can enforce device
  // bans (see the bans migration) without the app passing it call by call.
  final device = await DeviceIdentityService.instance.load();
  await Supabase.initialize(
    url: SupabaseConfig.url,
    publishableKey: SupabaseConfig.publishableKey,
    headers: {'x-device-id': device.id},
  );
  await PushNotificationsService.instance.initializeApp();
  runApp(const SabaLiveApp());
  DeepLinkService(rootNavigatorKey).start();
  PushNotificationsService.instance.setupMessaging();
}
