import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../app.dart';
import '../config/supabase_client.dart';
import '../router/app_nav.dart';

/// Push notifications (FCM). The server side lives in
/// supabase/migrations/20260929100000_push_notifications.sql and
/// supabase/functions/send-push — this is just the client half: requesting
/// permission, registering this device's token against the signed-in user,
/// showing a local notification when a push arrives while the app is
/// already open (FCM does NOT do this on its own — see setupMessaging()'s
/// doc comment), and opening the app to the Notifications screen on tap.
///
/// Firebase.initializeApp() needs android/app/google-services.json (and
/// ios/Runner/GoogleService-Info.plist for iOS) to actually succeed — until
/// those are added, initializeApp() below fails quietly and every method
/// here becomes a no-op, so the app runs exactly as it did before this file
/// existed rather than crashing at startup.
class PushNotificationsService {
  PushNotificationsService._();
  static final instance = PushNotificationsService._();

  bool _initialized = false;
  String? _registeredToken;
  final _localNotifications = FlutterLocalNotificationsPlugin();

  static const _androidChannel = AndroidNotificationChannel(
    'default_channel',
    'Notifications',
    description: 'Live, messages, gifts, and wallet activity',
    importance: Importance.high,
  );

  /// Call from main() BEFORE runApp() — just the core native config, nothing
  /// that talks to FirebaseMessaging yet. On iOS, calling
  /// FirebaseMessaging.instance.getInitialMessage() (or anything else that
  /// round-trips to the native messaging SDK) before runApp() has started
  /// pumping frames can hang forever — the native side never gets a reply,
  /// main() never finishes awaiting, runApp() never executes, and the app
  /// sits on the native LaunchScreen indefinitely with nothing in the
  /// console. Firebase.initializeApp() itself is safe here since it's pure
  /// local config, no round-trip to Messaging's native layer.
  Future<void> initializeApp() async {
    try {
      await Firebase.initializeApp();
      _initialized = true;
    } catch (e) {
      debugPrint('Firebase.initializeApp failed (FCM not configured yet?): $e');
    }
  }

  /// Call from main() AFTER runApp() — sets up local-notification display
  /// and tap handling. See initializeApp()'s doc comment for why this can't
  /// run before runApp().
  ///
  /// FCM only auto-shows a system notification when the app is backgrounded
  /// or fully closed — a push that arrives while the app is open in the
  /// foreground is delivered silently to onMessage with nothing shown to
  /// the user unless the app displays it itself. That's what this wires up
  /// via flutter_local_notifications, using the same title/body the push
  /// already carries. Without this, testing by staying in the app looks
  /// exactly like "push isn't working" even though it is.
  Future<void> setupMessaging() async {
    if (!_initialized) return;
    await _initLocalNotifications();
    FirebaseMessaging.onMessageOpenedApp.listen(_handleTap);
    FirebaseMessaging.onMessage.listen(_showForegroundNotification);
    final initial = await FirebaseMessaging.instance.getInitialMessage();
    if (initial != null) _handleTap(initial);
  }

  Future<void> _initLocalNotifications() async {
    const androidInit = AndroidInitializationSettings('ic_launcher_foreground');
    // Permission is requested explicitly via FirebaseMessaging.requestPermission()
    // in registerForCurrentUser() below — asking again here would double-prompt
    // on iOS, so this init only sets up display, not permission.
    const iosInit = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    await _localNotifications.initialize(
      const InitializationSettings(android: androidInit, iOS: iosInit),
      onDidReceiveNotificationResponse: (response) {
        final context = rootNavigatorKey.currentContext;
        if (context != null) AppNav.notifications(context);
      },
    );
    await _localNotifications
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(_androidChannel);
  }

  void _showForegroundNotification(RemoteMessage message) {
    final notification = message.notification;
    if (notification == null) return;
    _localNotifications.show(
      notification.hashCode,
      notification.title,
      notification.body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          _androidChannel.id,
          _androidChannel.name,
          channelDescription: _androidChannel.description,
          importance: Importance.high,
          priority: Priority.high,
          icon: 'ic_launcher_foreground',
        ),
        iOS: const DarwinNotificationDetails(),
      ),
      payload: message.data['kind'] as String?,
    );
  }

  /// Call once a Supabase session exists — registering needs auth.uid().
  Future<void> registerForCurrentUser() async {
    if (!_initialized) return;
    try {
      final messaging = FirebaseMessaging.instance;
      final before = await messaging.getNotificationSettings();
      debugPrint('Push permission before request: ${before.authorizationStatus}');
      final settings = await messaging.requestPermission();
      debugPrint('Push permission after request: ${settings.authorizationStatus}');
      if (settings.authorizationStatus == AuthorizationStatus.denied) {
        // Nothing more to do — iOS/Android both only show the system
        // prompt once per install; the user has to re-enable it from the
        // OS Settings app themselves from here on. Not treated as an
        // error: declining notifications is a valid, expected choice.
        return;
      }
      if (Platform.isIOS) {
        // getToken() needs the device's APNS token first, which arrives
        // asynchronously from Apple's push service after requestPermission()
        // above — calling getToken() immediately can beat that round trip
        // and throw apns-token-not-set. There's no official "ready" future
        // for this, so poll briefly; it typically resolves within a couple
        // of seconds.
        for (var i = 0; i < 10 && await messaging.getAPNSToken() == null; i++) {
          await Future.delayed(const Duration(seconds: 1));
        }
      }
      final token = await messaging.getToken();
      debugPrint('FCM token: ${token == null ? 'null (registration will be skipped)' : 'obtained'}');
      if (token != null) await _register(token);
      messaging.onTokenRefresh.listen(_register);
    } catch (e) {
      debugPrint('FCM token registration failed: $e');
    }
  }

  Future<void> _register(String token) async {
    try {
      await supabase.rpc(
        'register_device_token',
        params: {'p_token': token, 'p_platform': Platform.isIOS ? 'ios' : 'android'},
      );
      _registeredToken = token;
    } catch (e) {
      debugPrint('register_device_token failed: $e');
    }
  }

  /// Call BEFORE supabase.auth.signOut() — the RPC needs the still-valid
  /// session to identify which token to remove.
  Future<void> onSignOut() async {
    final token = _registeredToken;
    if (token == null) return;
    _registeredToken = null;
    try {
      await supabase.rpc('unregister_device_token', params: {'p_token': token});
    } catch (e) {
      debugPrint('unregister_device_token failed: $e');
    }
  }

  void _handleTap(RemoteMessage message) {
    final context = rootNavigatorKey.currentContext;
    if (context == null) return;
    AppNav.notifications(context);
  }
}
