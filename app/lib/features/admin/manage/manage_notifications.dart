import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:bluechip_rewards/core/theme/app_colors.dart';
import 'package:bluechip_rewards/core/theme/app_palette.dart';
import '../../../core/widgets/common.dart';
import '../../../core/widgets/state_views.dart';
import '../../../providers/repositories.dart';

/// §29/§30 — Custom notifications: compose a title + message, choose to target
/// all users or a specific set, Send Now, and see a history of what was sent.
class ManageNotificationsScreen extends ConsumerStatefulWidget {
  const ManageNotificationsScreen({super.key});

  @override
  ConsumerState<ManageNotificationsScreen> createState() =>
      _ManageNotificationsScreenState();
}

class _ManageNotificationsScreenState
    extends ConsumerState<ManageNotificationsScreen> {
  final _title = TextEditingController();
  final _body = TextEditingController();
  String _target = 'all'; // all | specific
  final Set<String> _selectedIds = {};
  final Map<String, String> _selectedNames = {};
  bool _sending = false;
  int _historyKey = 0;

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final title = _title.text.trim();
    if (title.isEmpty) {
      showSnack(context, 'Title is required', error: true);
      return;
    }
    if (_target == 'specific' && _selectedIds.isEmpty) {
      showSnack(context, 'Select at least one user', error: true);
      return;
    }
    setState(() => _sending = true);
    try {
      final n = await ref.read(adminRepositoryProvider).sendNotification(
            title,
            _body.text.trim(),
            target: _target,
            userIds: _target == 'specific' ? _selectedIds.toList() : null,
          );
      if (!mounted) return;
      showSnack(context, 'Sent to $n user(s)');
      _title.clear();
      _body.clear();
      setState(() {
        _selectedIds.clear();
        _selectedNames.clear();
        _historyKey++;
      });
    } catch (e) {
      if (mounted) showSnack(context, '$e', error: true);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _pickUsers() async {
    final result = await showModalBottomSheet<Map<String, String>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _UserPickerSheet(
        preselected: Map.of(_selectedNames),
      ),
    );
    if (result != null) {
      setState(() {
        _selectedIds
          ..clear()
          ..addAll(result.keys);
        _selectedNames
          ..clear()
          ..addAll(result);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Custom notifications')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SectionCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Compose',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                const SizedBox(height: 12),
                TextField(
                  controller: _title,
                  decoration: const InputDecoration(labelText: 'Title'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _body,
                  maxLines: 4,
                  decoration: const InputDecoration(labelText: 'Message'),
                ),
                const SizedBox(height: 14),
                Text('Send to',
                    style: TextStyle(
                        color: context.cx.textSecondary,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'all', label: Text('All users')),
                    ButtonSegment(
                        value: 'specific', label: Text('Specific users')),
                  ],
                  selected: {_target},
                  onSelectionChanged: (s) =>
                      setState(() => _target = s.first),
                ),
                if (_target == 'specific') ...[
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: _pickUsers,
                    icon: const Icon(Icons.people_alt_rounded),
                    label: Text(_selectedIds.isEmpty
                        ? 'Choose recipients'
                        : '${_selectedIds.length} selected'),
                  ),
                  if (_selectedNames.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: _selectedNames.entries
                          .map((e) => Chip(
                                label: Text(e.value),
                                onDeleted: () => setState(() {
                                  _selectedIds.remove(e.key);
                                  _selectedNames.remove(e.key);
                                }),
                              ))
                          .toList(),
                    ),
                  ],
                ],
                const SizedBox(height: 16),
                ElevatedButton.icon(
                  onPressed: _sending ? null : _send,
                  style: ElevatedButton.styleFrom(
                      minimumSize: const Size.fromHeight(48)),
                  icon: _sending
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.send_rounded),
                  label: const Text('Send now'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Text('HISTORY',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  letterSpacing: .8,
                  color: AppColors.primary)),
          const SizedBox(height: 8),
          _HistoryList(key: ValueKey(_historyKey)),
        ],
      ),
    );
  }
}

class _HistoryList extends ConsumerWidget {
  const _HistoryList({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: ref.read(adminRepositoryProvider).notificationHistory(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        if (snap.hasError) {
          return ErrorView(error: snap.error!);
        }
        final rows = snap.data ?? [];
        if (rows.isEmpty) {
          return const EmptyView(
              icon: Icons.notifications_none_rounded,
              title: 'No custom notifications yet');
        }
        return Column(
          children: [
            for (final r in rows)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: SectionCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text('${r['title']}',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w800)),
                          ),
                          Pill(
                            r['target'] == 'specific'
                                ? '${r['recipients']} users'
                                : 'All',
                            color: AppColors.info,
                          ),
                        ],
                      ),
                      if ((r['body'] as String?)?.isNotEmpty == true) ...[
                        const SizedBox(height: 4),
                        Text('${r['body']}',
                            style:
                                TextStyle(color: context.cx.textSecondary)),
                      ],
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _UserPickerSheet extends ConsumerStatefulWidget {
  final Map<String, String> preselected;
  const _UserPickerSheet({required this.preselected});

  @override
  ConsumerState<_UserPickerSheet> createState() => _UserPickerSheetState();
}

class _UserPickerSheetState extends ConsumerState<_UserPickerSheet> {
  final _search = TextEditingController();
  late Map<String, String> _selected;
  List<Map<String, dynamic>> _users = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _selected = Map.of(widget.preselected);
    _load();
  }

  Future<void> _load([String? q]) async {
    setState(() => _loading = true);
    try {
      final res =
          await ref.read(adminRepositoryProvider).userOptions(search: q);
      setState(() {
        _users = res;
        _loading = false;
      });
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
          left: 12,
          right: 12,
          top: 12,
          bottom: MediaQuery.of(context).viewInsets.bottom + 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _search,
                  onSubmitted: _load,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search_rounded),
                    hintText: 'Search name / username / email',
                  ),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, _selected),
                child: Text('Done (${_selected.length})'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 360,
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    itemCount: _users.length,
                    itemBuilder: (_, i) {
                      final u = _users[i];
                      final id = u['id'] as String;
                      final name = (u['name'] ?? 'User').toString();
                      final email = (u['email'] ?? '').toString();
                      final checked = _selected.containsKey(id);
                      return CheckboxListTile(
                        value: checked,
                        title: Text(name),
                        subtitle: email.isEmpty ? null : Text(email),
                        onChanged: (v) => setState(() {
                          if (v == true) {
                            _selected[id] = name;
                          } else {
                            _selected.remove(id);
                          }
                        }),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
