import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/common.dart';
import '../../../core/widgets/state_views.dart';
import '../../../providers/repositories.dart';
import '../admin_providers.dart';

class AdminSettingsTab extends ConsumerWidget {
  const AdminSettingsTab({super.key});

  Future<void> _edit(BuildContext context, WidgetRef ref, String key,
      dynamic value, String? desc) async {
    final ctrl = TextEditingController(text: jsonEncode(value));
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(key),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (desc != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(desc,
                    style: TextStyle(
                        color: AppColors.textSecondary, fontSize: 13)),
              ),
            TextField(
              controller: ctrl,
              maxLines: null,
              decoration: const InputDecoration(
                labelText: 'JSON value',
                helperText: 'e.g. 50  or  "₹"  or  [{"amount":10,"weight":40}]',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Save')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final parsed = jsonDecode(ctrl.text.trim());
      await ref.read(adminRepositoryProvider).setSetting(key, parsed);
      ref.invalidate(adminSettingsProvider);
      if (context.mounted) showSnack(context, 'Saved');
    } catch (e) {
      if (context.mounted) {
        showSnack(context, 'Invalid JSON or error: $e', error: true);
      }
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
        data: (settings) => ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: settings.length,
          separatorBuilder: (_, __) => const SizedBox(height: 10),
          itemBuilder: (_, i) {
            final s = settings[i];
            return SectionCard(
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(s['key'] as String,
                    style: const TextStyle(fontWeight: FontWeight.w800)),
                subtitle: Text(
                  '${s['description'] ?? ''}\n${jsonEncode(s['value'])}',
                  style: TextStyle(color: AppColors.textSecondary),
                ),
                isThreeLine: true,
                trailing: const Icon(Icons.edit_rounded),
                onTap: () => _edit(context, ref, s['key'] as String,
                    s['value'], s['description'] as String?),
              ),
            );
          },
        ),
      ),
    );
  }
}
