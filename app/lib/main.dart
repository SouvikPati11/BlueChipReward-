import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import 'app.dart';
import 'core/config/app_config.dart';
import 'core/supabase/supabase_client.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

  await AppConfig.load();

  // Supabase is required; if unconfigured we still boot so the app can show a
  // clear configuration message instead of crashing.
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

  // AdMob — safe to initialise even without a real unit (test ads).
  unawaitedInit();

  runApp(ProviderScope(
    child: BlueChipApp(configError: initError),
  ));
}

void unawaitedInit() {
  MobileAds.instance.initialize();
}
