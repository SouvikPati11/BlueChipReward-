import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'core/config/app_config.dart';
import 'core/push/push_service.dart';
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

      if (!initError) {
        await PushService.init();
        // Flush any deep-link captured before the router existed (cold-start
        // notification tap).
        PushService.applyPendingRoute();

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
