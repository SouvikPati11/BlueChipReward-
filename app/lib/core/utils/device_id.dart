import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

/// A stable, install-scoped device identifier used purely as a fraud signal for
/// the server (same-device self-referral detection). It is NOT a hardware id and
/// carries no PII — a random value persisted on first use. Cleared on reinstall.
class DeviceId {
  static const _key = 'bcp_device_id';
  static String? _cached;

  static Future<String> get() async {
    if (_cached != null) return _cached!;
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(_key);
    if (id == null || id.isEmpty) {
      id = _generate();
      await prefs.setString(_key, id);
    }
    _cached = id;
    return id;
  }

  static String _generate() {
    final rnd = Random.secure();
    final bytes = List<int>.generate(16, (_) => rnd.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
