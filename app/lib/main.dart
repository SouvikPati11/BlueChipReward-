import 'dart:async';

import 'package:applovin_max/applovin_max.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:unity_ads_plugin/unity_ads_plugin.dart';

import 'app.dart';
import 'core/ads/rewarded_ad_manager.dart';
import 'core/config/app_config.dart';
import 'core/push/push_service.dart';
import 'core/push/reminder_service.dart';
import 'core/supabase/supabase_client.dart';

Future<void> main() async {
  // Guard the whole startup so no async error during init can take the app down
  // on launch — the worst case is a clear in-app message, never a crash.
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();

    // Framework errors are logged, not fatal.
    FlutterError.onError = FlutterError.presentError;

    await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

    await AppConfig.load();

    // Development diagnostics (debug/profile only, via assert): a SAFE summary
    // of the runtime config — booleans + lengths only, never the URL, key, or
    // any secret value — so a "login won't work" report can be traced to a
    // missing/misconfigured Supabase config directly from logcat.
    assert(() {
      final url = AppConfig.supabaseUrl;
      final key = AppConfig.supabaseAnonKey;
      debugPrint('BlueChip config → configured=${AppConfig.isConfigured} '
          'urlHttps=${url.startsWith('https://')} urlLen=${url.length} '
          'keyPresent=${key.isNotEmpty} keyLooksJwt=${key.startsWith('eyJ')} '
          'keyLen=${key.length}');
      return true;
    }());

    // Supabase is required; if it is unconfigured or fails to initialise we
    // still boot and show a clear message instead of crashing.
    var initError = false;
    if (AppConfig.isConfigured) {
      try {
        await Db.init();
      } catch (_) {
        initError = true;
      }
    } else {
      initError = true;
    }

    runApp(ProviderScope(child: BlueChipApp(configError: initError)));

    // Ads + push are non-critical and initialised AFTER the first frame. A
    // failure here (AdMob misconfiguration, or a placeholder Firebase config)
    // must never affect startup.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      MobileAds.instance.initialize().then((_) {}, onError: (_) {});

      // AppLovin MAX / Unity Ads initialise ONLY when their account keys are
      // configured (they cannot run — even in test mode — without them). When a
      // key is absent the network stays uninitialised and any placement set to
      // it falls back to AdMob test ads. Failures here never affect startup.
      try {
        final applovinKey = AppConfig.applovinSdkKey;
        if (applovinKey.isNotEmpty) {
          AppLovinMAX.initialize(applovinKey).then(
            (_) => RewardedAdManager.applovinReady = true,
            onError: (_) {},
          );
        }
      } catch (_) {/* non-fatal */}
      try {
        final unityId = AppConfig.unityGameId;
        if (unityId.isNotEmpty) {
          UnityAds.init(
            gameId: unityId,
            testMode: true,
            onComplete: () => RewardedAdManager.unityReady = true,
            onFailed: (error, message) {},
          );
        }
      } catch (_) {/* non-fatal */}

      if (!initError) {
        await PushService.init();
        // Flush any deep-link captured before the router existed (cold-start
        // notification tap).
        PushService.applyPendingRoute();

        // Schedule on-device daily reminders (local notifications, no server).
        // Respects the user's opt-out and notification permission.
        ReminderService.scheduleAll();

        // Keep the device token in sync with the session: (re)register on
        // sign-in / token refresh. Sign-out cleanup happens in signOut() before
        // the session ends.
        Db.auth.onAuthStateChange.listen((state) {
          final e = state.event;
          if (e == AuthChangeEvent.signedIn ||
              e == AuthChangeEvent.tokenRefreshed ||
              e == AuthChangeEvent.userUpdated) {
            PushService.registerCurrentToken();
          }
        });
      }
    });
  }, (error, stack) {
    debugPrint('BlueChip Rewards uncaught startup error: $error');
  });
}
