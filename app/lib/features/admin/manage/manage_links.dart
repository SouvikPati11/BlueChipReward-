import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/common.dart';
import '../../../core/widgets/state_views.dart';
import '../../../providers/repositories.dart';
import '../admin_providers.dart';
import 'package:bluechip_rewards/core/theme/app_palette.dart';

class ManageLinksScreen extends ConsumerWidget {
  const ManageLinksScreen({super.key});

  Future<void> _edit(BuildContext context, WidgetRef ref,
      [Map<String, dynamic>? existing]) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _LinkEditor(existing: existing),
    );
    if (saved == true) ref.invalidate(adminAppLinksProvider);
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, String id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete link?'),
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
      await ref.read(adminRepositoryProvider).deleteAppLink(id);
      ref.invalidate(adminAppLinksProvider);
      if (context.mounted) showSnack(context, 'Deleted');
    } catch (e) {
      if (context.mounted) showSnack(context, '$e', error: true);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(adminAppLinksProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Links')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(context, ref),
        icon: const Icon(Icons.add_rounded),
        label: const Text('New link'),
      ),
      body: async.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(
            error: e, onRetry: () => ref.invalidate(adminAppLinksProvider)),
        data: (list) {
          if (list.isEmpty) {
            return const EmptyView(
              icon: Icons.link_off_rounded,
              title: 'No links',
              subtitle: 'Add support, social or page links here.',
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: list.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (_, i) {
              final l = list[i];
              final active = l['active'] == true;
              return SectionCard(
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('${l['label']}',
                      style: const TextStyle(fontWeight: FontWeight.w800)),
                  subtitle: Text(
                      '${l['url']}\n${active ? 'Active' : 'Inactive'} · ${l['external'] == true ? 'External' : 'In-app'}',
                      style: TextStyle(color: context.cx.textSecondary)),
                  isThreeLine: true,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                          onPressed: () => _edit(context, ref, l),
                          icon: const Icon(Icons.edit_rounded)),
                      IconButton(
                          onPressed: () =>
                              _delete(context, ref, l['id'] as String),
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

class _LinkEditor extends ConsumerStatefulWidget {
  final Map<String, dynamic>? existing;
  const _LinkEditor({this.existing});

  @override
  ConsumerState<_LinkEditor> createState() => _LinkEditorState();
}

class _LinkEditorState extends ConsumerState<_LinkEditor> {
  late final TextEditingController _label;
  late final TextEditingController _url;
  late final TextEditingController _icon;
  late final TextEditingController _position;
  bool _external = true;
  bool _active = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _label = TextEditingController(text: '${e?['label'] ?? ''}');
    _url = TextEditingController(text: '${e?['url'] ?? ''}');
    _icon = TextEditingController(text: '${e?['icon'] ?? ''}');
    _position = TextEditingController(text: '${e?['position'] ?? 0}');
    _external = e?['external'] as bool? ?? true;
    _active = e?['active'] as bool? ?? true;
  }

  @override
  void dispose() {
    _label.dispose();
    _url.dispose();
    _icon.dispose();
    _position.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_label.text.trim().isEmpty || _url.text.trim().isEmpty) {
      showSnack(context, 'Label and URL are required', error: true);
      return;
    }
    setState(() => _saving = true);
    try {
      await ref.read(adminRepositoryProvider).saveAppLink({
        'id': widget.existing?['id'],
        'key': widget.existing?['key'],
        'label': _label.text.trim(),
        'url': _url.text.trim(),
        'icon': _icon.text.trim().isEmpty ? null : _icon.text.trim(),
        'external': _external,
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
          Text(widget.existing == null ? 'New link' : 'Edit link',
              style:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 14),
          TextField(
              controller: _label,
              decoration: const InputDecoration(labelText: 'Label')),
          const SizedBox(height: 10),
          TextField(
              controller: _url,
              decoration: InputDecoration(
                  labelText: _external ? 'URL (https://…)' : 'In-app route (/…)')),
          const SizedBox(height: 10),
          TextField(
              controller: _icon,
              decoration: const InputDecoration(
                  labelText: 'Icon name (optional)',
                  helperText: 'e.g. support_agent, send, help_center')),
          const SizedBox(height: 10),
          TextField(
              controller: _position,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Position')),
          SwitchListTile(
            value: _external,
            onChanged: (v) => setState(() => _external = v),
            title: const Text('External link'),
            subtitle: const Text('Off = navigate to an in-app route'),
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
