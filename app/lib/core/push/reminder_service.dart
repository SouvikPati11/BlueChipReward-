import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'push_service.dart';

/// A single user reminder: a daily local notification.
class _Reminder {
  final int id;
  final String route;
  final int hour;
  final int minute;
  final String title;
  final String body;
  const _Reminder(this.id, this.route, this.hour, this.minute, this.title,
      this.body);
}

/// On-device daily reminders using local notifications (§11). No server
/// scheduler and no paid Firebase dependency — the OS fires these even when the
/// app is closed. Everything is defensive: if the timezone can't be resolved or
/// permission is denied, scheduling simply no-ops.
class ReminderService {
  ReminderService._();

  static const String prefsEnabledKey = 'reminders_enabled';
  static const String _channelId = 'bluechip_reminders';
  static const String _channelName = 'Reminders';
  static const String _channelDesc =
      'Daily reminders for rewards, mining, quiz, tasks and more';

  // Reuse the shared plugin so there is one initialize()/tap handler app-wide.
  static FlutterLocalNotificationsPlugin get _plugin => PushService.plugin;
  static bool _ready = false;
  static bool _tzReady = false;

  // Sensible default local times. These repeat daily.
  static const List<_Reminder> _reminders = [
    _Reminder(9001, '/earn/daily', 10, 0, 'Daily reward ready 🎁',
        'Claim your daily BCP before the day ends.'),
    _Reminder(9002, '/earn/mining', 18, 0, 'Mining claim ⛏️',
        'Your mined BCP is waiting — open the app to claim it.'),
    _Reminder(9003, '/earn/quiz', 12, 0, 'Daily quiz 🧠',
        'A new quiz is available. Answer to earn BCP.'),
    _Reminder(9004, '/earn/tasks', 16, 0, 'Tasks to complete ✅',
        'Finish a task and earn extra BCP today.'),
    _Reminder(9005, '/earn/scratch', 9, 0, 'Scratch card available 🎫',
        'A fresh scratch card may be ready — try your luck!'),
    _Reminder(9006, '/earn/ads', 20, 0, 'Watch & earn 📺',
        'Rewarded ads are available. Watch to earn BCP.'),
  ];

  static Future<void> _ensureInit() async {
    if (!_tzReady) {
      try {
        tzdata.initializeTimeZones();
        final name = await FlutterTimezone.getLocalTimezone();
        tz.setLocalLocation(tz.getLocation(name));
      } catch (_) {
        // Fall back to UTC — reminders still fire, just on UTC wall-clock.
        try {
          tz.setLocalLocation(tz.getLocation('UTC'));
        } catch (_) {}
      }
      _tzReady = true;
    }
    if (_ready) return;
    // PushService.ensureLocalInit() performs the single plugin initialize and
    // installs the tap → deep-link handler; we only add our own channel.
    await PushService.ensureLocalInit();
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(const AndroidNotificationChannel(
          _channelId,
          _channelName,
          description: _channelDesc,
          importance: Importance.defaultImportance,
        ));
    _ready = true;
  }

  /// Request the notification permission (Android 13+). Returns false if denied
  /// — callers should degrade gracefully.
  static Future<bool> requestPermission() async {
    try {
      await _ensureInit();
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      final granted = await android?.requestNotificationsPermission();
      return granted ?? true;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> isEnabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(prefsEnabledKey) ?? true; // opt-out model
    } catch (_) {
      return true;
    }
  }

  static Future<void> setEnabled(bool enabled) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(prefsEnabledKey, enabled);
    } catch (_) {}
    if (enabled) {
      await scheduleAll();
    } else {
      await cancelAll();
    }
  }

  /// Schedule (or reschedule) all daily reminders. Safe to call on every app
  /// start — it cancels and re-adds so the schedule never drifts or duplicates.
  static Future<void> scheduleAll() async {
    if (!await isEnabled()) return;
    final ok = await requestPermission();
    if (!ok) return; // denied → nothing scheduled, app keeps working
    try {
      await _ensureInit();
      for (final r in _reminders) {
        await _plugin.cancel(r.id);
        await _plugin.zonedSchedule(
          r.id,
          r.title,
          r.body,
          _nextInstanceOf(r.hour, r.minute),
          NotificationDetails(
            android: AndroidNotificationDetails(
              _channelId,
              _channelName,
              channelDescription: _channelDesc,
              importance: Importance.defaultImportance,
              priority: Priority.defaultPriority,
              icon: 'ic_notification',
            ),
          ),
          // Inexact avoids needing the restricted exact-alarm permission.
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          matchDateTimeComponents: DateTimeComponents.time, // repeat daily
          payload: r.route,
        );
      }
    } catch (e) {
      debugPrint('ReminderService: scheduling failed ($e)');
    }
  }

  static Future<void> cancelAll() async {
    try {
      await _ensureInit();
      for (final r in _reminders) {
        await _plugin.cancel(r.id);
      }
    } catch (_) {}
  }

  static tz.TZDateTime _nextInstanceOf(int hour, int minute) {
    final now = tz.TZDateTime.now(tz.local);
    var scheduled =
        tz.TZDateTime(tz.local, now.year, now.month, now.day, hour, minute);
    if (!scheduled.isAfter(now)) {
      scheduled = scheduled.add(const Duration(days: 1));
    }
    return scheduled;
  }
}
