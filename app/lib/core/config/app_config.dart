import 'package:flutter/services.dart' show rootBundle;

/// Runtime configuration. Values resolve in this order:
///   1. --dart-define (compile-time, wins in CI/release)
///   2. assets/.env (bundled fallback for local/dev)
///
/// The Supabase anon key is public by design (protected by RLS). The
/// service-role key must NEVER appear here or anywhere in the app.
class AppConfig {
  AppConfig._();

  static final Map<String, String> _env = {};

  static Future<void> load() async {
    try {
      final raw = await rootBundle.loadString('assets/.env');
      for (final line in raw.split('\n')) {
        final t = line.trim();
        if (t.isEmpty || t.startsWith('#') || !t.contains('=')) continue;
        final i = t.indexOf('=');
        _env[t.substring(0, i).trim()] = t.substring(i + 1).trim();
      }
    } catch (_) {
      // asset missing — rely on dart-define only
    }
  }

  static String _get(String key, String define) {
    if (define.isNotEmpty) return define;
    return _env[key] ?? '';
  }

  static String get supabaseUrl => _get(
        'SUPABASE_URL',
        const String.fromEnvironment('SUPABASE_URL'),
      );

  static String get supabaseAnonKey => _get(
        'SUPABASE_ANON_KEY',
        const String.fromEnvironment('SUPABASE_ANON_KEY'),
      );

  static String get googleWebClientId => _get(
        'GOOGLE_WEB_CLIENT_ID',
        const String.fromEnvironment('GOOGLE_WEB_CLIENT_ID'),
      );

  static String get admobRewardedAdUnit => _get(
        'ADMOB_REWARDED_AD_UNIT',
        const String.fromEnvironment('ADMOB_REWARDED_AD_UNIT'),
      );

  static bool get isConfigured =>
      supabaseUrl.isNotEmpty &&
      !supabaseUrl.contains('YOUR-PROJECT') &&
      supabaseAnonKey.isNotEmpty &&
      !supabaseAnonKey.contains('YOUR-');
}
