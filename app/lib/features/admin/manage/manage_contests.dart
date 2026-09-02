import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/common.dart';
import '../../../core/widgets/state_views.dart';
import '../../../providers/repositories.dart';
import '../admin_providers.dart';
import 'package:bluechip_rewards/core/theme/app_palette.dart';

class ManageContestsScreen extends ConsumerWidget {
  const ManageContestsScreen({super.key});

  Future<void> _edit(BuildContext context, WidgetRef ref,
      [Map<String, dynamic>? existing]) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ContestEditor(existing: existing),
    );
    if (saved == true) ref.invalidate(adminContestsProvider);
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, String id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete contest?'),
        content: const Text('This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(adminRepositoryProvider).deleteContest(id);
      ref.invalidate(adminContestsProvider);
      if (context.mounted) showSnack(context, 'Deleted');
    } catch (e) {
      if (context.mounted) showSnack(context, '$e', error: true);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(adminContestsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Contests')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(context, ref),
        icon: const Icon(Icons.add_rounded),
        label: const Text('New contest'),
      ),
      body: async.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(
            error: e, onRetry: () => ref.invalidate(adminContestsProvider)),
        data: (list) {
          if (list.isEmpty) {
            return const EmptyView(
              icon: Icons.emoji_events_outlined,
              title: 'No contests',
              subtitle: 'Create a BCP-earning or referral contest.',
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: list.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (_, i) {
              final c = list[i];
              final active = c['active'] == true;
              final type = c['target_type'] == 'referral_count'
                  ? 'referrals'
                  : 'BCP';
              return SectionCard(
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('${c['name']}',
                      style: const TextStyle(fontWeight: FontWeight.w800)),
                  subtitle: Text(
                      'Target ${c['target_value']} $type · +${c['reward']} BCP · ${((c['duration_hours'] as num?)?.toInt() ?? 0) ~/ 24}d · ${active ? 'Active' : 'Inactive'}',
                      style: TextStyle(color: context.cx.textSecondary)),
                  isThreeLine: true,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                          onPressed: () => _edit(context, ref, c),
                          icon: const Icon(Icons.edit_rounded)),
                      IconButton(
                          onPressed: () =>
                              _delete(context, ref, c['id'] as String),
                          icon: const Icon(Icons.delete_outline_rounded)),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _ContestEditor extends ConsumerStatefulWidget {
  final Map<String, dynamic>? existing;
  const _ContestEditor({this.existing});

  @override
  ConsumerState<_ContestEditor> createState() => _ContestEditorState();
}

class _ContestEditorState extends ConsumerState<_ContestEditor> {
  late final _name =
      TextEditingController(text: widget.existing?['name'] ?? '');
  late final _target = TextEditingController(
      text: '${widget.existing?['target_value'] ?? 500}');
  late final _reward =
      TextEditingController(text: '${widget.existing?['reward'] ?? 100}');
  late final _durationDays = TextEditingController(
      text: '${((widget.existing?['duration_hours'] as num?)?.toInt() ?? 168) ~/ 24}');
  late final _rules =
      TextEditingController(text: widget.existing?['rules'] ?? '');
  String _type = 'bcp_earned';
  bool _requiresAd = false;
  bool _active = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) {
      _type = e['target_type'] ?? 'bcp_earned';
      _requiresAd = e['requires_ad'] ?? false;
      _active = e['active'] ?? true;
    }
  }

  @override
  void dispose() {
    for (final c in [_name, _target, _reward, _durationDays, _rules]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      showSnack(context, 'Name is required', error: true);
      return;
    }
    setState(() => _saving = true);
    try {
      await ref.read(adminRepositoryProvider).saveContest({
        'id': widget.existing?['id'],
        'name': _name.text.trim(),
        'target_type': _type,
        'target_value': int.tryParse(_target.text.trim()) ?? 0,
        'reward': int.tryParse(_reward.text.trim()) ?? 0,
        'duration_hours': (int.tryParse(_durationDays.text.trim()) ?? 7) * 24,
        'requires_ad': _requiresAd,
        'rules': _rules.text.trim().isEmpty ? null : _rules.text.trim(),
        'active': _active,
        'position': widget.existing?['position'] ?? 0,
      });
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) showSnack(context, '$e', error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.existing == null ? 'New contest' : 'Edit contest',
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 14),
            TextField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Contest name')),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              value: _type,
              decoration: const InputDecoration(labelText: 'Target type'),
              items: const [
                DropdownMenuItem(
                    value: 'bcp_earned', child: Text('BCP earned')),
                DropdownMenuItem(
                    value: 'referral_count', child: Text('Referral count')),
              ],
              onChanged: (v) => setState(() => _type = v ?? 'bcp_earned'),
            ),
            const SizedBox(height: 10),
            TextField(
                controller: _target,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Target value')),
            const SizedBox(height: 10),
            TextField(
                controller: _reward,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Reward (BCP)')),
            const SizedBox(height: 10),
            TextField(
                controller: _durationDays,
                keyboardType: TextInputType.number,
                decoration:
                    const InputDecoration(labelText: 'Duration (days)')),
            const SizedBox(height: 10),
            TextField(
                controller: _rules,
                maxLines: 2,
                decoration:
                    const InputDecoration(labelText: 'Rules / instructions')),
            SwitchListTile(
              value: _requiresAd,
              onChanged: (v) => setState(() => _requiresAd = v),
              title: const Text('Require rewarded ad to claim'),
              contentPadding: EdgeInsets.zero,
            ),
            SwitchListTile(
              value: _active,
              onChanged: (v) => setState(() => _active = v),
              title: const Text('Active'),
              contentPadding: EdgeInsets.zero,
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2.2, color: Colors.white))
                  : const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }
}
