import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:bluechip_rewards/core/theme/app_colors.dart';
import 'package:bluechip_rewards/core/theme/app_palette.dart';
import '../../../core/widgets/common.dart';
import '../../../core/widgets/state_views.dart';
import '../../../providers/repositories.dart';

/// Admin table for Scratch Card rules. Each rule is a band of the day's scratch
/// index → reward range, cooldown between scratches, wait-after-previous-rule
/// and daily limit. Scratch always uses exactly ONE rewarded ad (not admin
/// configurable). The server validates too; the client mirrors the rules so the
/// admin sees errors immediately.
final _scratchRulesProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
  return ref.watch(adminRepositoryProvider).scratchRules();
});

class ManageScratchRulesScreen extends ConsumerWidget {
  const ManageScratchRulesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(_scratchRulesProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Scratch Card Rules')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(context, ref, null),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Add rule'),
      ),
      body: async.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(
            error: e, onRetry: () => ref.invalidate(_scratchRulesProvider)),
        data: (rules) {
          if (rules.isEmpty) {
            return const EmptyView(
                icon: Icons.style_rounded,
                title: 'No scratch rules',
                subtitle: 'Add a rule to control rewards & cooldowns.');
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 90),
            itemCount: rules.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (_, i) {
              final r = rules[i];
              final active = r['active'] == true;
              return SectionCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text('Cards ${r['from_card']}–${r['to_card']}',
                              style: const TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.w800)),
                        ),
                        Pill(active ? 'ACTIVE' : 'OFF',
                            color: active
                                ? AppColors.success
                                : AppColors.textSecondary),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                        '${r['min_reward']}–${r['max_reward']} BCP • 1 ad\n'
                        'Cooldown ${_fmt(r['cooldown_seconds'])}'
                        '${((r['wait_after_seconds'] as num?)?.toInt() ?? 0) > 0 ? '\nWait after previous rule: ${_fmt(r['wait_after_seconds'])}' : ''}'
                        '${((r['daily_limit'] as num?)?.toInt() ?? 0) > 0 ? '\nDaily limit: ${r['daily_limit']}' : ''}',
                        style: TextStyle(color: context.cx.textSecondary)),
                    Row(
                      children: [
                        const Spacer(),
                        TextButton.icon(
                          onPressed: () => _edit(context, ref, r),
                          icon: const Icon(Icons.edit_rounded, size: 18),
                          label: const Text('Edit'),
                        ),
                        TextButton.icon(
                          onPressed: () async {
                            try {
                              await ref
                                  .read(adminRepositoryProvider)
                                  .deleteScratchRule(r['id'] as String);
                              ref.invalidate(_scratchRulesProvider);
                            } catch (e) {
                              if (context.mounted) {
                                showSnack(context, '$e', error: true);
                              }
                            }
                          },
                          style: TextButton.styleFrom(
                              foregroundColor: AppColors.danger),
                          icon: const Icon(Icons.delete_outline_rounded, size: 18),
                          label: const Text('Delete'),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  static String _fmt(dynamic secs) {
    final s = (secs as num?)?.toInt() ?? 0;
    if (s >= 3600) return '${(s / 3600).toStringAsFixed(s % 3600 == 0 ? 0 : 1)}h';
    if (s >= 60) return '${(s / 60).round()}m';
    return '${s}s';
  }

  Future<void> _edit(
      BuildContext context, WidgetRef ref, Map<String, dynamic>? r) async {
    final from = TextEditingController(text: '${r?['from_card'] ?? ''}');
    final to = TextEditingController(text: '${r?['to_card'] ?? ''}');
    final min = TextEditingController(text: '${r?['min_reward'] ?? ''}');
    final max = TextEditingController(text: '${r?['max_reward'] ?? ''}');
    final cooldown =
        TextEditingController(text: '${r?['cooldown_seconds'] ?? 3600}');
    final wait =
        TextEditingController(text: '${r?['wait_after_seconds'] ?? 0}');
    final daily = TextEditingController(text: '${r?['daily_limit'] ?? 0}');
    bool active = r?['active'] ?? true;

    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => Padding(
          padding: EdgeInsets.only(
              left: 16,
              right: 16,
              top: 16,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 16),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(r == null ? 'New scratch rule' : 'Edit scratch rule',
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w800)),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(child: _num(from, 'Scratch from')),
                  const SizedBox(width: 10),
                  Expanded(child: _num(to, 'Scratch to')),
                ]),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(child: _num(min, 'Min reward (BCP)')),
                  const SizedBox(width: 10),
                  Expanded(child: _num(max, 'Max reward (BCP)')),
                ]),
                const SizedBox(height: 10),
                _num(cooldown, 'Cooldown between scratches (seconds)'),
                const SizedBox(height: 10),
                _num(wait, 'Wait after previous rule (seconds)'),
                const SizedBox(height: 10),
                _num(daily, 'Daily limit (0 = none)'),
                const SizedBox(height: 8),
                Text(
                    'Each scratch uses exactly one rewarded ad (skipped automatically '
                    'when the Reward-ads master switch is off).',
                    style: TextStyle(color: context.cx.textSecondary, fontSize: 12)),
                SwitchListTile(
                  value: active,
                  onChanged: (v) => setState(() => active = v),
                  title: const Text('Active'),
                  contentPadding: EdgeInsets.zero,
                ),
                const SizedBox(height: 4),
                ElevatedButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Save'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (ok != true) return;

    final fromV = int.tryParse(from.text.trim());
    final toV = int.tryParse(to.text.trim());
    final minV = int.tryParse(min.text.trim());
    final maxV = int.tryParse(max.text.trim());
    // Client-side validation mirrors the server.
    if (fromV == null || toV == null || fromV < 1 || toV < fromV) {
      if (context.mounted) {
        showSnack(context, 'Scratch range invalid (from ≤ to, from ≥ 1)',
            error: true);
      }
      return;
    }
    if (minV == null || maxV == null || minV < 0 || maxV < minV) {
      if (context.mounted) {
        showSnack(context, 'Reward invalid (0 ≤ min ≤ max)', error: true);
      }
      return;
    }
    try {
      // Scratch always uses exactly ONE rewarded ad (not admin-configurable) —
      // the repository + server force 1 ad / 0 delay.
      await ref.read(adminRepositoryProvider).saveScratchRule({
        'id': r?['id'],
        'from_card': fromV,
        'to_card': toV,
        'min_reward': minV,
        'max_reward': maxV,
        'cooldown_seconds': int.tryParse(cooldown.text.trim()) ?? 3600,
        'wait_after_seconds': int.tryParse(wait.text.trim()) ?? 0,
        'daily_limit': int.tryParse(daily.text.trim()) ?? 0,
        'active': active,
      });
      ref.invalidate(_scratchRulesProvider);
    } catch (e) {
      if (context.mounted) showSnack(context, _friendly('$e'), error: true);
    }
  }

  static Widget _num(TextEditingController c, String label) => TextField(
        controller: c,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(labelText: label, isDense: true),
      );

  static String _friendly(String e) {
    if (e.contains('RANGE_OVERLAP')) {
      return 'Ranges overlap another active rule. Use non-overlapping bands (e.g. 1–4 and 5–10).';
    }
    if (e.contains('INVALID_RANGE')) return 'Scratch range is invalid.';
    if (e.contains('INVALID_REWARD')) return 'Reward range is invalid.';
    if (e.contains('INVALID_NEGATIVE')) return 'Values cannot be negative.';
    return e;
  }
}
