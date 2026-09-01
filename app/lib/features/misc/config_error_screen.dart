import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';
import 'package:bluechip_rewards/core/theme/app_palette.dart';

/// Shown when Supabase credentials are missing/invalid so the app degrades
/// gracefully instead of crashing at launch.
class ConfigErrorScreen extends StatelessWidget {
  const ConfigErrorScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.settings_suggest_rounded,
                  size: 72, color: AppColors.primary),
              const SizedBox(height: 20),
              Text('Configuration required',
                  style: Theme.of(context)
                      .textTheme
                      .headlineSmall
                      ?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(height: 12),
              Text(
                'BlueChip Rewards needs your Supabase URL and anon key.\n\n'
                'Set them in app/assets/config.env, or pass them at build time with '
                '--dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...',
                textAlign: TextAlign.center,
                style: TextStyle(color: context.cx.textSecondary, height: 1.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
