import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../router/app_router.dart';
import '../supabase/supabase_client.dart';

// Must match the FCM default channel id injected into AndroidManifest by
// tool/patch_android.py so background/terminated notifications land here.
const String kPushChannelId = 'bluechip_default';
const String _channelName = 'General notifications';
const String _channelDesc = 'Rewards, announcements and reminders';

/// Background isolate entry point (app in background OR terminated). We send
/// data-only FCM messages, so the system does not auto-display them — we build
/// and post the notification ourselves here, exactly once.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  try {
    await Firebase.initializeApp();
  } catch (_) {
    // No/placeholder Firebase config — nothing to show.
    return;
  }
  await PushService.ensureLocalInit();
  await PushService.showFromMessage(message);
}

/// Wires Firebase Cloud Messaging into the app: permission, token lifecycle,
/// foreground/background/terminated display, deep-link routing and duplicate
/// prevention. Entirely defensive — if Firebase is not configured (placeholder
/// google-services.json), every call degrades to a no-op and the in-app
/// notification system is completely unaffected.
class PushService {
  PushService._();

  static final FlutterLocalNotificationsPlugin _local =
      FlutterLocalNotificationsPlugin();
  /// The shared local-notifications plugin. Reminder scheduling reuses this so
  /// there is a single `initialize` (single tap handler) across the app.
  static FlutterLocalNotificationsPlugin get plugin => _local;
  static bool _started = false;
  static bool _localReady = false;
  static bool _available = false;
  static String? _pendingRoute;

  /// Call once after the first frame. Safe to call again (no-op).
  static Future<void> init() async {
    if (_started) return;
    _started = true;

    try {
      await Firebase.initializeApp();
      _available = true;
    } catch (e) {
      // Placeholder/missing Firebase project — push stays inert.
      debugPrint('PushService: Firebase unavailable, push disabled ($e)');
      _available = false;
      return;
    }

    await ensureLocalInit();

    // If the app was launched by tapping a local notification (terminated →
    // open), route to its destination.
    try {
      final launch = await _local.getNotificationAppLaunchDetails();
      if (launch?.didNotificationLaunchApp == true) {
        final payload = launch!.notificationResponse?.payload;
        if (payload != null && payload.isNotEmpty) _route(payload);
      }
    } catch (_) {}

    // Ask for notification permission (Android 13+ / iOS).
    try {
      await FirebaseMessaging.instance.requestPermission();
    } catch (_) {}

    // Register the background handler (must be a top-level function).
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

    // Foreground data messages → show a local notification.
    FirebaseMessaging.onMessage.listen((m) {
      showFromMessage(m);
    });

    // FCM notification-type messages tapped from background/terminated. We send
    // data-only messages (handled above), but keep these for completeness.
    FirebaseMessaging.onMessageOpenedApp.listen((m) {
      final route = (m.data['route'] ?? '').toString();
      if (route.isNotEmpty) _route(route);
    });
    try {
      final initial = await FirebaseMessaging.instance.getInitialMessage();
      final route = (initial?.data['route'] ?? '').toString();
      if (route.isNotEmpty) _route(route);
    } catch (_) {}

    // Token lifecycle: refreshes update the server; register the current one.
    FirebaseMessaging.instance.onTokenRefresh.listen(_saveToken);
    await registerCurrentToken();
  }

  /// Idempotently initialise the local-notifications plugin + Android channel.
  /// Called from both the main isolate and the background isolate.
  static Future<void> ensureLocalInit() async {
    if (_localReady) return;
    const androidInit = AndroidInitializationSettings('ic_notification');
    const initSettings = InitializationSettings(android: androidInit);
    await _local.initialize(
      initSettings,
      onDidReceiveNotificationResponse: (resp) {
        final payload = resp.payload;
        if (payload != null && payload.isNotEmpty) _route(payload);
      },
    );
    await _local
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(const AndroidNotificationChannel(
          kPushChannelId,
          _channelName,
          description: _channelDesc,
          importance: Importance.high,
        ));
    _localReady = true;
  }

  /// Fetch the current FCM token and register it for the signed-in user.
  static Future<void> registerCurrentToken() async {
    if (!_available || Db.uid == null) return;
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token != null) await _saveToken(token);
    } catch (e) {
      debugPrint('PushService: getToken failed ($e)');
    }
  }

  static Future<void> _saveToken(String token) async {
    if (Db.uid == null) return;
    try {
      await Db.client.rpc('register_device_token',
          params: {'p_token': token, 'p_platform': 'android'});
    } catch (e) {
      debugPrint('PushService: register_device_token failed ($e)');
    }
  }

  /// On sign-out: remove this device's token so a signed-out phone (or the next
  /// account) never receives the previous user's pushes.
  static Future<void> unregisterCurrentToken() async {
    if (!_available) return;
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token != null) {
        try {
          await Db.client
              .rpc('unregister_device_token', params: {'p_token': token});
        } catch (_) {}
      }
      await FirebaseMessaging.instance.deleteToken();
    } catch (_) {}
  }

  /// Build + post a local notification for a message, de-duplicated by its id.
  static Future<void> showFromMessage(RemoteMessage message) async {
    await ensureLocalInit();
    final data = message.data;
    final notif = message.notification;
    final title =
        (notif?.title ?? data['title'] ?? 'BlueChip Rewards').toString();
    final body = (notif?.body ?? data['body'] ?? '').toString();
    final id = (data['id'] ?? '').toString();
    final route = (data['route'] ?? '').toString();

    // Duplicate prevention: the same custom_notifications id must show once,
    // even if delivered to more than one handler/state.
    if (id.isNotEmpty && await _seen(id)) return;

    final notifId = id.isNotEmpty
        ? (id.hashCode & 0x7fffffff)
        : (DateTime.now().millisecondsSinceEpoch & 0x7fffffff);

    await _local.show(
      notifId,
      title,
      body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          kPushChannelId,
          _channelName,
          channelDescription: _channelDesc,
          importance: Importance.high,
          priority: Priority.high,
          icon: 'ic_notification',
        ),
      ),
      payload: route,
    );
  }

  static void _route(String route) {
    final dest = route.isEmpty ? '/notifications' : route;
    final r = appRouter;
    if (r == null) {
      _pendingRoute = dest; // router not built yet; apply once it is
      return;
    }
    try {
      r.go(dest);
    } catch (_) {
      r.go('/notifications');
    }
  }

  /// Called once the router exists to flush a deep-link captured during a cold
  /// start (notification tap that launched the app).
  static void applyPendingRoute() {
    final pending = _pendingRoute;
    if (pending == null) return;
    _pendingRoute = null;
    _route(pending);
  }

  static Future<bool> _seen(String id) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      const key = 'push_seen_ids';
      final list = prefs.getStringList(key) ?? <String>[];
      if (list.contains(id)) return true;
      list.add(id);
      if (list.length > 100) list.removeRange(0, list.length - 100);
      await prefs.setStringList(key, list);
      return false;
    } catch (_) {
      return false;
    }
  }
}
