import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/config/constants.dart';
import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';
import 'features/misc/config_error_screen.dart';

class BlueChipApp extends ConsumerWidget {
  final bool configError;
  const BlueChipApp({super.key, this.configError = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (configError) {
      return MaterialApp(
        title: K.appName,
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light,
        home: const ConfigErrorScreen(),
      );
    }

    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      title: K.appName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      routerConfig: router,
    );
  }
}
