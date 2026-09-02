import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/common.dart';
import '../../../core/widgets/state_views.dart';
import '../../../providers/repositories.dart';
import '../admin_providers.dart';

/// Control type for a setting.
enum SettingKind { toggle, number, percent, text, json }

class _Spec {
  final String key;
  final String label;
  final String? help;
  final SettingKind kind;
  const _Spec(this.key, this.label, this.kind, [this.help]);
}

/// Human-readable, categorized admin settings (no raw key dumps). Any setting
/// not covered by a spec below still appears under "Other" as a JSON editor, so
/// nothing is ever hidden or lost.
class AdminSettingsTab extends ConsumerWidget {
  const AdminSettingsTab({super.key});

  static const Map<String, List<_Spec>> _categories = {
    'General': [
      _Spec('signup_bonus', 'Signup bonus (BCP)', SettingKind.number),
      _Spec('maintenance_mode', 'Maintenance mode', SettingKind.toggle,
          'Pause earning (client hint)'),
    ],
    'Withdrawal': [
      _Spec('withdrawal_min', 'Global minimum withdrawal (BCP)',
          SettingKind.number,
          'Per-method minimum, rate & fee are set under Content → Payment methods'),
    ],
    // Refer & Earn is managed by the dedicated card editor
    // (Content → Referral levels), so it is intentionally not duplicated here.
    'Mining': [
      _Spec('mining_enabled', 'Mining enabled', SettingKind.toggle),
      _Spec('mining_rate_per_hour', 'Base mining rate (BCP/hour)',
          SettingKind.number),
      _Spec('mining_session_hours', 'Session duration (hours)',
          SettingKind.number),
      _Spec('mining_max_boosts', 'Maximum boosts', SettingKind.number),
      _Spec('mining_boost_pct', 'Extra reward per boost (%)',
          SettingKind.percent),
      _Spec('mining_boost_cooldown_hours', 'Boost cooldown (hours)',
          SettingKind.number),
      _Spec('mining_boost_compounding', 'Boosts compound', SettingKind.toggle),
      _Spec('mining_boost_requires_ad', 'Boost requires rewarded ad',
          SettingKind.toggle),
      _Spec('mining_enabled', 'Mining enabled', SettingKind.toggle),
      _Spec('mining_start_requires_ad', 'Start requires rewarded ad',
          SettingKind.toggle),
      _Spec('mining_claim_requires_ad', 'Claim requires rewarded ad',
          SettingKind.toggle),
      _Spec('mining_max_claims', 'Max claims per session', SettingKind.number),
    ],
    'Daily Reward': [
      _Spec('daily_reward_days', 'Day-wise rewards (7-day cycle)',
          SettingKind.json, 'e.g. [10,20,30,40,50,70,100]'),
    ],
    'Scratch Card': [
      _Spec('scratch_daily_cap', 'Cards per day', SettingKind.number),
      _Spec('scratch_cards_config', 'Per-card reward ranges', SettingKind.json,
          '[{"enabled":true,"min":50,"max":100}, ...] — one entry per card'),
    ],
    'Ads & Rewards': [
      _Spec('ads_system_enabled', 'Reward ads', SettingKind.toggle,
          'Master switch — OFF disables all rewarded ads'),
      _Spec('banner_ads_enabled', 'Banner ads', SettingKind.toggle,
          'Master switch — OFF disables all banner ads'),
      _Spec('rewarded_ads_enabled', 'Rewarded ads (secondary master)',
          SettingKind.toggle),
      _Spec('ads_reward', 'Watch-ad reward (BCP)', SettingKind.number),
      _Spec('rewarded_daily_cap', 'Completed rewarded ads / day (all sections)',
          SettingKind.number),
      _Spec('ads_daily_cap', 'Watch-Ads rewards per day', SettingKind.number),
      _Spec('ads_min_gap_seconds', 'Min seconds between ads',
          SettingKind.number),
      _Spec('ad_gate_contest', 'Contest · rewarded required',
          SettingKind.toggle),
      // Rewarded per section
      _Spec('ad_gate_daily', 'Daily · rewarded required', SettingKind.toggle),
      _Spec('ad_gate_scratch', 'Scratch · rewarded required',
          SettingKind.toggle),
      _Spec('ad_gate_quiz', 'Quiz · rewarded required', SettingKind.toggle),
      _Spec('ad_gate_watch_ads', 'Watch Ads · rewarded', SettingKind.toggle),
      _Spec('ad_gate_tasks', 'Tasks · rewarded required', SettingKind.toggle),
      // Banner per section
      _Spec('banner_daily', 'Daily · banner', SettingKind.toggle),
      _Spec('banner_scratch', 'Scratch · banner', SettingKind.toggle),
      _Spec('banner_mining', 'Mining · banner', SettingKind.toggle),
      _Spec('banner_watch_ads', 'Watch Ads · banner', SettingKind.toggle),
      _Spec('banner_quiz', 'Quiz · banner', SettingKind.toggle),
      _Spec('banner_tasks', 'Tasks · banner', SettingKind.toggle),
    ],
    'Notifications': [
      _Spec('reminder_daily_enabled', 'Daily reward reminder',
          SettingKind.toggle),
      _Spec('reminder_mining_enabled', 'Mining ready reminder',
          SettingKind.toggle),
      _Spec('reminder_boost_enabled', 'Boost ready reminder',
          SettingKind.toggle),
      _Spec('reminder_unclaimed_enabled', 'Unclaimed BCP reminder',
          SettingKind.toggle),
    ],
  };

  Future<void> _save(BuildContext context, WidgetRef ref, String key,
      dynamic value) async {
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
          final others = settings
              .where((s) => !covered.contains(s['key']))
              .toList();

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              for (final entry in _categories.entries)
                _CategoryCard(
                  title: entry.key,
                  children: [
                    for (final sp in entry.value)
                      if (byKey.containsKey(sp.key))
                        _SettingControl(
                          spec: sp,
                          value: byKey[sp.key]!['value'],
                          onSave: (v) => _save(context, ref, sp.key, v),
                        ),
                  ],
                ),
              if (others.isNotEmpty)
                _CategoryCard(
                  title: 'Other',
                  children: [
                    for (final s in others)
                      _SettingControl(
                        spec: _Spec(s['key'] as String, s['key'] as String,
                            SettingKind.json, s['description'] as String?),
                        value: s['value'],
                        onSave: (v) => _save(context, ref, s['key'] as String, v),
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

class _CategoryCard extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const _CategoryCard({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: SectionCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title.toUpperCase(),
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    letterSpacing: .8,
                    color: AppColors.primary)),
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _SettingControl extends StatefulWidget {
  final _Spec spec;
  final dynamic value;
  final ValueChanged<dynamic> onSave;
  const _SettingControl(
      {required this.spec, required this.value, required this.onSave});

  @override
  State<_SettingControl> createState() => _SettingControlState();
}

class _SettingControlState extends State<_SettingControl> {
  late TextEditingController _ctrl;
  late bool _bool;

  @override
  void initState() {
    super.initState();
    _bool = widget.value == true;
    _ctrl = TextEditingController(text: _initialText());
  }

  String _initialText() {
    switch (widget.spec.kind) {
      case SettingKind.json:
        return const JsonEncoder.withIndent('  ').convert(widget.value);
      case SettingKind.text:
        return '${widget.value ?? ''}';
      default:
        return '${widget.value ?? ''}';
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sp = widget.spec;
    if (sp.kind == SettingKind.toggle) {
      return SwitchListTile(
        value: _bool,
        contentPadding: EdgeInsets.zero,
        title: Text(sp.label),
        subtitle: sp.help != null ? Text(sp.help!) : null,
        onChanged: (v) {
          setState(() => _bool = v);
          widget.onSave(v);
        },
      );
    }

    final isNum =
        sp.kind == SettingKind.number || sp.kind == SettingKind.percent;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: TextField(
              controller: _ctrl,
              keyboardType: isNum
                  ? const TextInputType.numberWithOptions(decimal: true)
                  : (sp.kind == SettingKind.json
                      ? TextInputType.multiline
                      : TextInputType.text),
              maxLines: sp.kind == SettingKind.json ? null : 1,
              decoration: InputDecoration(
                labelText: sp.label,
                helperText: sp.help,
                helperMaxLines: 2,
                isDense: true,
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.save_rounded),
            color: AppColors.primary,
            onPressed: () {
              final text = _ctrl.text.trim();
              dynamic value;
              try {
                switch (sp.kind) {
                  case SettingKind.number:
                    value = num.parse(text);
                    break;
                  case SettingKind.percent:
                    value = num.parse(text);
                    break;
                  case SettingKind.json:
                    value = jsonDecode(text);
                    break;
                  case SettingKind.text:
                    value = text;
                    break;
                  case SettingKind.toggle:
                    value = _bool;
                    break;
                }
              } catch (_) {
                showSnack(context, 'Invalid value for ${sp.label}',
                    error: true);
                return;
              }
              widget.onSave(value);
            },
          ),
        ],
      ),
    );
  }
}
