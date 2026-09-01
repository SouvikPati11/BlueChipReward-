import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import 'app.dart';
import 'core/config/app_config.dart';
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

    // Ads are non-critical and initialised AFTER the first frame. A failure
    // here (e.g. an AdMob misconfiguration) must never affect startup.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      MobileAds.instance.initialize().then((_) {}, onError: (_) {});
    });
  }, (error, stack) {
    debugPrint('BlueChip Rewards uncaught startup error: $error');
  });
}
