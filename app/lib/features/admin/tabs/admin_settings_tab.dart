import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/common.dart';
import '../../../core/widgets/state_views.dart';
import '../../../providers/repositories.dart';
import '../admin_providers.dart';
import 'admin_setting_control.dart';

/// Human-readable, categorized admin settings (no raw key dumps). Any setting
/// not covered by a spec below still appears under "Other" as a JSON editor, so
/// nothing is ever hidden or lost.
///
/// Ads settings are intentionally NOT here — they live in the dedicated
/// Admin → Ads panel (see AdminAdsTab). Ad keys are excluded from the "Other"
/// fallback via [isAdSettingKey] so they are never duplicated in Config.
class AdminSettingsTab extends ConsumerWidget {
  const AdminSettingsTab({super.key});

  static const Map<String, List<Spec>> _categories = {
    'General': [
      Spec('signup_bonus', 'Signup bonus (BCP)', SettingKind.number),
      Spec('maintenance_mode', 'Maintenance mode', SettingKind.toggle,
          'Pause earning (client hint)'),
    ],
    'Withdrawal': [
      Spec('withdrawal_min', 'Global minimum withdrawal (BCP)',
          SettingKind.number,
          'Per-method minimum, rate & fee are set under Content → Payment methods'),
    ],
    // Refer & Earn is managed by the dedicated card editor
    // (Content → Referral levels), so it is intentionally not duplicated here.
    'Mining': [
      Spec('mining_enabled', 'Mining enabled', SettingKind.toggle),
      Spec('mining_rate_per_hour', 'Base mining rate (BCP/hour)',
          SettingKind.number),
      Spec('mining_session_hours', 'Session duration (hours)',
          SettingKind.number),
      Spec('mining_max_boosts', 'Maximum boosts', SettingKind.number),
      Spec('mining_boost_pct', 'Extra reward per boost (%)',
          SettingKind.percent),
      Spec('mining_boost_cooldown_hours', 'Boost cooldown (hours)',
          SettingKind.number),
      Spec('mining_boost_duration_minutes', 'Boost active duration (minutes)',
          SettingKind.number),
      Spec('mining_boost_compounding', 'Boosts compound', SettingKind.toggle),
      Spec('mining_boost_requires_ad', 'Boost requires rewarded ad',
          SettingKind.toggle),
      Spec('mining_start_requires_ad', 'Start requires rewarded ad',
          SettingKind.toggle),
      Spec('mining_claim_requires_ad', 'Claim requires rewarded ad',
          SettingKind.toggle),
      Spec('mining_max_claims', 'Max claims per session', SettingKind.number),
    ],
    'Daily Reward': [
      Spec('daily_reward_days', 'Day-wise rewards (7-day cycle)',
          SettingKind.json, 'e.g. [10,20,30,40,50,70,100]'),
    ],
    'Scratch Card': [
      Spec('scratch_daily_cap', 'Cards per day', SettingKind.number),
      Spec('scratch_cards_config', 'Per-card reward ranges', SettingKind.json,
          '[{"enabled":true,"min":50,"max":100}, ...] — one entry per card'),
    ],
    'Automatic reminders': [
      Spec('reminder_daily_enabled', 'Daily reward reminder',
          SettingKind.toggle),
      Spec('reminder_daily_title', 'Daily · title', SettingKind.text),
      Spec('reminder_daily_body', 'Daily · message', SettingKind.text),
      Spec('reminder_daily_window_hours', 'Daily · min hours between sends',
          SettingKind.number),
      Spec('reminder_mining_enabled', 'Mining ready reminder',
          SettingKind.toggle),
      Spec('reminder_mining_title', 'Mining · title', SettingKind.text),
      Spec('reminder_mining_body', 'Mining · message', SettingKind.text),
      Spec('reminder_mining_window_hours', 'Mining · min hours between sends',
          SettingKind.number),
      Spec('reminder_boost_enabled', 'Boost ready reminder',
          SettingKind.toggle),
      Spec('reminder_boost_title', 'Boost · title', SettingKind.text),
      Spec('reminder_boost_body', 'Boost · message', SettingKind.text),
      Spec('reminder_boost_window_hours',
          'Boost · min hours between sends (0 = use cooldown)',
          SettingKind.number),
      Spec('reminder_unclaimed_enabled', 'Unclaimed BCP reminder',
          SettingKind.toggle),
      Spec('reminder_unclaimed_title', 'Unclaimed · title', SettingKind.text),
      Spec('reminder_unclaimed_body', 'Unclaimed · message', SettingKind.text),
      Spec('reminder_unclaimed_window_hours',
          'Unclaimed · min hours between sends', SettingKind.number),
    ],
  };

  Future<void> _save(
      BuildContext context, WidgetRef ref, String key, dynamic value) async {
    try {
      await ref.read(adminRepositoryProvider).setSetting(key, value);
      ref.invalidate(adminSettingsProvider);
      if (context.mounted) showSnack(context, 'Saved');
    } catch (e) {
      if (context.mounted) showSnack(context, '$e', error: true);
    }
  }

  Future<void> _broadcast(BuildContext context, WidgetRef ref) async {
    final title = TextEditingController();
    final body = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Send announcement'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
                controller: title,
                decoration: const InputDecoration(labelText: 'Title')),
            const SizedBox(height: 10),
            TextField(
                controller: body,
                maxLines: 3,
                decoration: const InputDecoration(labelText: 'Message')),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Send')),
        ],
      ),
    );
    if (ok != true || title.text.trim().isEmpty) return;
    try {
      await ref
          .read(adminRepositoryProvider)
          .broadcast(title.text.trim(), body.text.trim());
      if (context.mounted) showSnack(context, 'Announcement sent');
    } catch (e) {
      if (context.mounted) showSnack(context, '$e', error: true);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(adminSettingsProvider);
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _broadcast(context, ref),
        icon: const Icon(Icons.campaign_rounded),
        label: const Text('Broadcast'),
      ),
      body: async.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(
            error: e, onRetry: () => ref.invalidate(adminSettingsProvider)),
        data: (settings) {
          final byKey = {for (final s in settings) s['key'] as String: s};
          final covered = <String>{};
          for (final specs in _categories.values) {
            for (final sp in specs) {
              covered.add(sp.key);
            }
          }
          // Exclude anything covered above AND every Ads key — those belong to
          // the dedicated Admin → Ads panel, never to Config.
          final others = settings
              .where((s) =>
                  !covered.contains(s['key']) &&
                  !isAdSettingKey(s['key'] as String))
              .toList();

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              for (final entry in _categories.entries)
                CategoryCard(
                  title: entry.key,
                  children: [
                    for (final sp in entry.value)
                      if (byKey.containsKey(sp.key))
                        SettingControl(
                          spec: sp,
                          value: byKey[sp.key]!['value'],
                          onSave: (v) => _save(context, ref, sp.key, v),
                        ),
                  ],
                ),
              if (others.isNotEmpty)
                CategoryCard(
                  title: 'Other',
                  children: [
                    for (final s in others)
                      SettingControl(
                        spec: Spec(s['key'] as String, s['key'] as String,
                            SettingKind.json, s['description'] as String?),
                        value: s['value'],
                        onSave: (v) =>
                            _save(context, ref, s['key'] as String, v),
                      ),
                  ],
                ),
              const SizedBox(height: 80),
            ],
          );
        },
      ),
    );
  }
}
