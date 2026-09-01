import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/common.dart';
import '../../../core/widgets/state_views.dart';
import '../../../providers/repositories.dart';
import '../admin_providers.dart';
import 'package:bluechip_rewards/core/theme/app_palette.dart';

class ManageMilestonesScreen extends ConsumerWidget {
  const ManageMilestonesScreen({super.key});

  Future<void> _edit(BuildContext context, WidgetRef ref,
      [Map<String, dynamic>? existing]) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _MilestoneEditor(existing: existing),
    );
    if (saved == true) ref.invalidate(adminInviteMilestonesProvider);
  }

  Future<void> _delete(
      BuildContext context, WidgetRef ref, String id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete milestone?'),
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
      await ref.read(adminRepositoryProvider).deleteInviteMilestone(id);
      ref.invalidate(adminInviteMilestonesProvider);
      if (context.mounted) showSnack(context, 'Deleted');
    } catch (e) {
      if (context.mounted) showSnack(context, '$e', error: true);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(adminInviteMilestonesProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Invite milestones')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(context, ref),
        icon: const Icon(Icons.add_rounded),
        label: const Text('New milestone'),
      ),
      body: async.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(
            error: e,
            onRetry: () => ref.invalidate(adminInviteMilestonesProvider)),
        data: (list) {
          if (list.isEmpty) {
            return const EmptyView(
              icon: Icons.emoji_events_outlined,
              title: 'No milestones',
              subtitle: 'Add one to reward users for inviting friends.',
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: list.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (_, i) {
              final m = list[i];
              final active = m['active'] == true;
              final auto = m['auto_verify'] == true;
              return SectionCard(
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('Invite ${m['threshold']} → ${m['reward']} BCP',
                      style: const TextStyle(fontWeight: FontWeight.w800)),
                  subtitle: Text(
                      '${auto ? 'Auto-verified' : 'Manual proof'} · ${active ? 'Active' : 'Inactive'}',
                      style: TextStyle(color: context.cx.textSecondary)),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                          onPressed: () => _edit(context, ref, m),
                          icon: const Icon(Icons.edit_rounded)),
                      IconButton(
                          onPressed: () =>
                              _delete(context, ref, m['id'] as String),
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

class _MilestoneEditor extends ConsumerStatefulWidget {
  final Map<String, dynamic>? existing;
  const _MilestoneEditor({this.existing});

  @override
  ConsumerState<_MilestoneEditor> createState() => _MilestoneEditorState();
}

class _MilestoneEditorState extends ConsumerState<_MilestoneEditor> {
  late final TextEditingController _threshold;
  late final TextEditingController _reward;
  late final TextEditingController _position;
  bool _autoVerify = true;
  bool _active = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _threshold = TextEditingController(text: '${e?['threshold'] ?? ''}');
    _reward = TextEditingController(text: '${e?['reward'] ?? ''}');
    _position = TextEditingController(text: '${e?['position'] ?? 0}');
    _autoVerify = e?['auto_verify'] as bool? ?? true;
    _active = e?['active'] as bool? ?? true;
  }

  @override
  void dispose() {
    _threshold.dispose();
    _reward.dispose();
    _position.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final threshold = int.tryParse(_threshold.text.trim());
    final reward = int.tryParse(_reward.text.trim());
    if (threshold == null || threshold < 1 || reward == null) {
      showSnack(context, 'Enter a valid threshold and reward', error: true);
      return;
    }
    setState(() => _saving = true);
    try {
      await ref.read(adminRepositoryProvider).saveInviteMilestone({
        'id': widget.existing?['id'],
        'threshold': threshold,
        'reward': reward,
        'auto_verify': _autoVerify,
        'active': _active,
        'position': int.tryParse(_position.text.trim()) ?? 0,
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
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(widget.existing == null ? 'New milestone' : 'Edit milestone',
              style:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 14),
          TextField(
            controller: _threshold,
            keyboardType: TextInputType.number,
            decoration:
                const InputDecoration(labelText: 'Invites required'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _reward,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Reward (BCP)'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _position,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Position'),
          ),
          SwitchListTile(
            value: _autoVerify,
            onChanged: (v) => setState(() => _autoVerify = v),
            title: const Text('Auto-verify (check referral count server-side)'),
            subtitle: const Text('Off = user uploads screenshot proof for review'),
          ),
          SwitchListTile(
            value: _active,
            onChanged: (v) => setState(() => _active = v),
            title: const Text('Active'),
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
    );
  }
}
