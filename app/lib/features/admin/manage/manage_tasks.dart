import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:bluechip_rewards/core/theme/app_colors.dart';
import 'package:bluechip_rewards/core/theme/app_palette.dart';
import '../../../core/widgets/common.dart';
import '../../../core/widgets/state_views.dart';
import '../../../providers/repositories.dart';
import '../admin_providers.dart';

class ManageTasksScreen extends ConsumerWidget {
  const ManageTasksScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(adminAllTasksProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Manage Tasks')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(context, ref, null),
        icon: const Icon(Icons.add_rounded),
        label: const Text('New task'),
      ),
      body: async.when(
        loading: () => const LoadingView(),
        error: (e, _) =>
            ErrorView(error: e, onRetry: () => ref.invalidate(adminAllTasksProvider)),
        data: (tasks) {
          if (tasks.isEmpty) {
            return const EmptyView(
                icon: Icons.checklist_rounded, title: 'No tasks yet');
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 90),
            itemCount: tasks.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (_, i) {
              final t = tasks[i];
              final active = t['active'] == true;
              return SectionCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(t['title'] ?? '',
                              style: const TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.w800)),
                        ),
                        Pill(active ? 'ACTIVE' : 'HIDDEN',
                            color: active ? AppColors.success : AppColors.textSecondary),
                      ],
                    ),
                    if (t['description'] != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(t['description'],
                            style: TextStyle(color: context.cx.textSecondary)),
                      ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        BcpAmount((t['reward'] as num?)?.toInt() ?? 0, showSign: true),
                        const Spacer(),
                        TextButton.icon(
                          onPressed: () => _edit(context, ref, t),
                          icon: const Icon(Icons.edit_rounded, size: 18),
                          label: const Text('Edit'),
                        ),
                        TextButton.icon(
                          onPressed: () => _delete(context, ref, t['id'] as String),
                          style: TextButton.styleFrom(foregroundColor: AppColors.danger),
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

  Future<void> _delete(BuildContext context, WidgetRef ref, String id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete task?'),
        content: const Text('This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: AppColors.danger),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(adminRepositoryProvider).deleteTask(id);
      ref.invalidate(adminAllTasksProvider);
    } catch (e) {
      if (context.mounted) showSnack(context, '$e', error: true);
    }
  }

  Future<void> _edit(
      BuildContext context, WidgetRef ref, Map<String, dynamic>? task) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _TaskForm(task: task),
    );
    if (saved == true) ref.invalidate(adminAllTasksProvider);
  }
}

class _TaskForm extends ConsumerStatefulWidget {
  final Map<String, dynamic>? task;
  const _TaskForm({this.task});

  @override
  ConsumerState<_TaskForm> createState() => _TaskFormState();
}

class _TaskFormState extends ConsumerState<_TaskForm> {
  late final _title = TextEditingController(text: widget.task?['title'] ?? '');
  late final _desc =
      TextEditingController(text: widget.task?['description'] ?? '');
  late final _reward = TextEditingController(
      text: (widget.task?['reward'] ?? 100).toString());
  late final _url =
      TextEditingController(text: widget.task?['action_url'] ?? '');
  late final _instructions =
      TextEditingController(text: widget.task?['instructions'] ?? '');
  String _type = 'link_visit';
  bool _autoVerify = true;
  bool _active = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    if (widget.task != null) {
      _type = widget.task!['type'] ?? 'link_visit';
      _autoVerify = widget.task!['auto_verify'] ?? true;
      _active = widget.task!['active'] ?? true;
    }
  }

  @override
  void dispose() {
    for (final c in [_title, _desc, _reward, _url, _instructions]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await ref.read(adminRepositoryProvider).saveTask({
        'id': widget.task?['id'],
        'title': _title.text.trim(),
        'description': _desc.text.trim(),
        'type': _type,
        'reward': int.tryParse(_reward.text.trim()) ?? 0,
        'action_url': _url.text.trim().isEmpty ? null : _url.text.trim(),
        'instructions':
            _instructions.text.trim().isEmpty ? null : _instructions.text.trim(),
        'auto_verify': _autoVerify,
        'active': _active,
        'position': widget.task?['position'] ?? 0,
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
            Text(widget.task == null ? 'New task' : 'Edit task',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 14),
            TextField(controller: _title, decoration: const InputDecoration(labelText: 'Title')),
            const SizedBox(height: 10),
            TextField(controller: _desc, decoration: const InputDecoration(labelText: 'Description')),
            const SizedBox(height: 10),
            TextField(controller: _reward, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Reward (BCP)')),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              value: _type,
              decoration: const InputDecoration(labelText: 'Type'),
              items: const [
                DropdownMenuItem(value: 'link_visit', child: Text('Link visit')),
                DropdownMenuItem(value: 'telegram', child: Text('Telegram')),
                DropdownMenuItem(value: 'social', child: Text('Social')),
                DropdownMenuItem(value: 'invite', child: Text('Invite')),
                DropdownMenuItem(value: 'custom', child: Text('Custom')),
              ],
              onChanged: (v) => setState(() => _type = v ?? 'link_visit'),
            ),
            const SizedBox(height: 10),
            TextField(controller: _url, decoration: const InputDecoration(labelText: 'Action URL (optional)')),
            const SizedBox(height: 10),
            TextField(controller: _instructions, decoration: const InputDecoration(labelText: 'Instructions (optional)')),
            SwitchListTile(
              value: _autoVerify,
              onChanged: (v) => setState(() => _autoVerify = v),
              title: const Text('Auto-verify (reward immediately)'),
              contentPadding: EdgeInsets.zero,
            ),
            SwitchListTile(
              value: _active,
              onChanged: (v) => setState(() => _active = v),
              title: const Text('Active'),
              contentPadding: EdgeInsets.zero,
            ),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white))
                  : const Text('Save task'),
            ),
          ],
        ),
      ),
    );
  }
}
