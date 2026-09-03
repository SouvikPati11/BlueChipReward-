import 'dart:math';

import 'package:android_id/android_id.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A device identifier used purely as a fraud signal for the server
/// (same-device self-referral detection). It carries no PII.
///
/// Preference order:
///   1. Android's Settings.Secure.ANDROID_ID — survives an app reinstall (it
///      only resets on a factory reset / new user profile), so it is much
///      harder to bypass by clearing app data or reinstalling than a random
///      value. This directly satisfies "reinstalling must not reset protection".
///   2. A random value persisted in shared_preferences — fallback when
///      ANDROID_ID is unavailable (older APIs, non-Android, or a read failure).
///
/// It is combined server-side with the self-referral relationship check and the
/// review queue, so no user is blocked on this single signal alone.
class DeviceId {
  static const _key = 'bcp_device_id';
  static const _androidIdPlugin = AndroidId();
  static String? _cached;

  static Future<String> get() async {
    if (_cached != null) return _cached!;

    // 1) Prefer the reinstall-stable Android id.
    try {
      final aid = await _androidIdPlugin.getId();
      if (aid != null && aid.trim().isNotEmpty) {
        _cached = 'aid_${aid.trim()}';
        // Persist so a later ANDROID_ID read failure still returns the same id.
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(_key, _cached!);
        } catch (_) {}
        return _cached!;
      }
    } catch (e) {
      debugPrint('DeviceId: ANDROID_ID unavailable ($e)');
    }

    // 2) Fallback: a random, persisted value.
    try {
      final prefs = await SharedPreferences.getInstance();
      var id = prefs.getString(_key);
      if (id == null || id.isEmpty) {
        id = _generate();
        await prefs.setString(_key, id);
      }
      _cached = id;
      return id;
    } catch (_) {
      _cached = _generate();
      return _cached!;
    }
  }

  static String _generate() {
    final rnd = Random.secure();
    final bytes = List<int>.generate(16, (_) => rnd.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
