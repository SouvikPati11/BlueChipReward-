import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:bluechip_rewards/core/theme/app_colors.dart';
import 'package:bluechip_rewards/core/theme/app_palette.dart';
import '../../../core/widgets/common.dart';
import '../../../core/widgets/state_views.dart';
import '../../../providers/repositories.dart';
import '../admin_providers.dart';

/// Editable multi-level referral configuration — one card per level (no JSON).
/// Each level supports a Fixed reward and/or a Percentage reward, both at once.
class ManageReferralScreen extends ConsumerStatefulWidget {
  const ManageReferralScreen({super.key});

  @override
  ConsumerState<ManageReferralScreen> createState() =>
      _ManageReferralScreenState();
}

class _LevelDraft {
  bool enabled;
  bool fixedEnabled;
  final TextEditingController fixed;
  bool percentEnabled;
  final TextEditingController percent;
  _LevelDraft({
    required this.enabled,
    required this.fixedEnabled,
    required num fixed,
    required this.percentEnabled,
    required num percent,
  })  : fixed = TextEditingController(text: _fmt(fixed)),
        percent = TextEditingController(text: _fmt(percent));

  static String _fmt(num n) => n == n.roundToDouble() ? '${n.toInt()}' : '$n';

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'fixed_enabled': fixedEnabled,
        'fixed': num.tryParse(fixed.text.trim()) ?? 0,
        'percent_enabled': percentEnabled,
        'percent': num.tryParse(percent.text.trim()) ?? 0,
      };

  void dispose() {
    fixed.dispose();
    percent.dispose();
  }
}

class _ManageReferralScreenState extends ConsumerState<ManageReferralScreen> {
  bool _systemEnabled = true;
  final _qualifying = TextEditingController(text: '500');
  final List<_LevelDraft> _levels = [];
  bool _loaded = false;
  bool _saving = false;

  @override
  void dispose() {
    _qualifying.dispose();
    for (final l in _levels) {
      l.dispose();
    }
    super.dispose();
  }

  void _hydrate(List<Map<String, dynamic>> settings) {
    if (_loaded) return;
    final byKey = {for (final s in settings) s['key'] as String: s['value']};
    _systemEnabled = byKey['referral_system_enabled'] != false;
    final qual = byKey['referral_qualifying_amount'];
    if (qual is num) _qualifying.text = '${qual.toInt()}';
    final raw = byKey['referral_levels'];
    if (raw is List) {
      for (final e in raw) {
        final m = (e as Map).cast<String, dynamic>();
        // Support both new + legacy shapes.
        final isLegacy = m.containsKey('type');
        _levels.add(_LevelDraft(
          enabled: m['enabled'] as bool? ?? true,
          fixedEnabled: isLegacy
              ? m['type'] == 'fixed'
              : m['fixed_enabled'] as bool? ?? false,
          fixed: isLegacy
              ? (m['type'] == 'fixed' ? (m['value'] as num? ?? 0) : 0)
              : (m['fixed'] as num? ?? 0),
          percentEnabled: isLegacy
              ? m['type'] == 'percent'
              : m['percent_enabled'] as bool? ?? false,
          percent: isLegacy
              ? (m['type'] == 'percent' ? (m['value'] as num? ?? 0) : 0)
              : (m['percent'] as num? ?? 0),
        ));
      }
    }
    if (_levels.isEmpty) _addLevel();
    _loaded = true;
  }

  void _addLevel() {
    setState(() => _levels.add(_LevelDraft(
        enabled: true,
        fixedEnabled: true,
        fixed: 0,
        percentEnabled: false,
        percent: 0)));
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await ref.read(adminRepositoryProvider).setReferralLevels(
            _levels.map((l) => l.toJson()).toList(),
            _systemEnabled,
            num.tryParse(_qualifying.text.trim()) ?? 0,
          );
      ref.invalidate(adminSettingsProvider);
      if (mounted) showSnack(context, 'Referral configuration saved');
    } catch (e) {
      if (mounted) showSnack(context, '$e', error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(adminSettingsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Referral levels')),
      body: async.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(
            error: e, onRetry: () => ref.invalidate(adminSettingsProvider)),
        data: (settings) {
          _hydrate(settings);
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              SectionCard(
                child: Column(
                  children: [
                    SwitchListTile(
                      value: _systemEnabled,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Referral system enabled'),
                      onChanged: (v) => setState(() => _systemEnabled = v),
                    ),
                    TextField(
                      controller: _qualifying,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Percentage reward base (BCP)',
                        helperText:
                            'A percent reward pays this × the level %. e.g. 10% of 500 = 50',
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              for (var i = 0; i < _levels.length; i++)
                _levelCard(i),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _addLevel,
                icon: const Icon(Icons.add_rounded),
                label: const Text('Add level'),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2.2, color: Colors.white))
                      : const Text('Save configuration'),
                ),
              ),
              const SizedBox(height: 24),
            ],
          );
        },
      ),
    );
  }

  Widget _levelCard(int i) {
    final l = _levels[i];
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: SectionCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 15,
                  backgroundColor: AppColors.primary.withValues(alpha: .12),
                  child: Text('L${i + 1}',
                      style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          color: AppColors.primary)),
                ),
                const SizedBox(width: 10),
                const Expanded(
                    child: Text('Level',
                        style: TextStyle(fontWeight: FontWeight.w800))),
                Switch(
                  value: l.enabled,
                  onChanged: (v) => setState(() => l.enabled = v),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline_rounded),
                  color: AppColors.danger,
                  onPressed: _levels.length <= 1
                      ? null
                      : () => setState(() {
                            _levels.removeAt(i).dispose();
                          }),
                ),
              ],
            ),
            if (l.enabled) ...[
              Row(
                children: [
                  Expanded(
                    child: SwitchListTile(
                      value: l.fixedEnabled,
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: const Text('Fixed'),
                      onChanged: (v) => setState(() => l.fixedEnabled = v),
                    ),
                  ),
                  SizedBox(
                    width: 110,
                    child: TextField(
                      controller: l.fixed,
                      enabled: l.fixedEnabled,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                          labelText: 'BCP', isDense: true),
                    ),
                  ),
                ],
              ),
              Row(
                children: [
                  Expanded(
                    child: SwitchListTile(
                      value: l.percentEnabled,
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: const Text('Percentage'),
                      onChanged: (v) => setState(() => l.percentEnabled = v),
                    ),
                  ),
                  SizedBox(
                    width: 110,
                    child: TextField(
                      controller: l.percent,
                      enabled: l.percentEnabled,
                      keyboardType: const TextInputType.numberWithOptions(
                          decimal: true),
                      decoration:
                          const InputDecoration(labelText: '%', isDense: true),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
