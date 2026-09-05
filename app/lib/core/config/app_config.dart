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
    // NOTE: the bundled config file must NOT be a dotfile — Flutter's asset
    // bundler skips names starting with '.', which silently drops the file
    // from release APKs. We read a normal filename, with the legacy dotfile as
    // a fallback for older builds.
    for (final path in const ['assets/config.env', 'assets/.env']) {
      try {
        final raw = await rootBundle.loadString(path);
        for (final line in raw.split('\n')) {
          final t = line.trim();
          if (t.isEmpty || t.startsWith('#') || !t.contains('=')) continue;
          final i = t.indexOf('=');
          _env[t.substring(0, i).trim()] = t.substring(i + 1).trim();
        }
        if (_env.isNotEmpty) return; // loaded successfully
      } catch (_) {
        // try the next candidate
      }
    }
  }

  static String _get(String key, String define) {
    if (define.isNotEmpty) return define;
    return _env[key] ?? '';
  }

  static String get supabaseUrl => _normalizeUrl(_get(
        'SUPABASE_URL',
        const String.fromEnvironment('SUPABASE_URL'),
      ));

  static String get supabaseAnonKey => _unquote(_get(
        'SUPABASE_ANON_KEY',
        const String.fromEnvironment('SUPABASE_ANON_KEY'),
      ));

  /// Defensive normalisation for the Supabase URL. A URL that is missing the
  /// scheme, or that carries a trailing slash, makes gotrue build endpoints like
  /// `https://ref.supabase.co//auth/v1/token`, whose non-JSON error page then
  /// fails to decode — surfacing as a generic FormatException at sign-in instead
  /// of a clean auth error. Fixing the value here makes sign-in robust to a
  /// mistyped secret without ever changing a correctly-entered URL.
  static String _normalizeUrl(String value) {
    var s = _unquote(value);
    if (s.isEmpty) return s;
    if (!s.startsWith('http://') && !s.startsWith('https://')) s = 'https://$s';
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  /// Strip surrounding quotes/whitespace a build-time value may carry.
  static String _unquote(String value) {
    var s = value.trim();
    if (s.length >= 2 &&
        ((s.startsWith('"') && s.endsWith('"')) ||
            (s.startsWith("'") && s.endsWith("'")))) {
      s = s.substring(1, s.length - 1).trim();
    }
    return s;
  }

  static String get googleWebClientId => _get(
        'GOOGLE_WEB_CLIENT_ID',
        const String.fromEnvironment('GOOGLE_WEB_CLIENT_ID'),
      );

  static String get admobRewardedAdUnit => _get(
        'ADMOB_REWARDED_AD_UNIT',
        const String.fromEnvironment('ADMOB_REWARDED_AD_UNIT'),
      );

  static String get admobBannerAdUnit => _get(
        'ADMOB_BANNER_AD_UNIT',
        const String.fromEnvironment('ADMOB_BANNER_AD_UNIT'),
      );

  // AppLovin MAX / Unity Ads identifiers. These are account-level keys (NOT
  // production ad-unit ids); the SDKs cannot initialise — even in test mode —
  // without them. When empty, that network is left uninitialised and any
  // placement configured to use it falls back to AdMob test ads.
  static String get applovinSdkKey => _get(
        'APPLOVIN_SDK_KEY',
        const String.fromEnvironment('APPLOVIN_SDK_KEY'),
      );

  static String get unityGameId => _get(
        'UNITY_GAME_ID',
        const String.fromEnvironment('UNITY_GAME_ID'),
      );

  static bool get isConfigured =>
      supabaseUrl.isNotEmpty &&
      !supabaseUrl.contains('YOUR-PROJECT') &&
      supabaseAnonKey.isNotEmpty &&
      !supabaseAnonKey.contains('YOUR-');
}
