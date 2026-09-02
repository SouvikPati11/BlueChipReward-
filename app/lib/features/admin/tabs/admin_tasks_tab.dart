import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/supabase/supabase_client.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/common.dart';
import '../../../core/widgets/state_views.dart';
import '../../../providers/repositories.dart';
import '../admin_providers.dart';
import 'package:bluechip_rewards/core/theme/app_palette.dart';

/// Task submissions awaiting manual review — shows the user, task, the admin's
/// proof instruction and the user's submitted proof (text with copy, or a
/// screenshot preview), with approve/reject.
class AdminTasksTab extends ConsumerWidget {
  const AdminTasksTab({super.key});

  Future<void> _review(
      BuildContext context, WidgetRef ref, String id, bool approve) async {
    try {
      await ref.read(adminRepositoryProvider).reviewTask(id, approve);
      ref.invalidate(adminTaskSubmissionsProvider('pending'));
      ref.invalidate(adminAnalyticsProvider);
      if (context.mounted) {
        showSnack(context, approve ? 'Approved & rewarded' : 'Rejected');
      }
    } catch (e) {
      if (context.mounted) showSnack(context, '$e', error: true);
    }
  }

  Future<void> _viewScreenshot(BuildContext context, String path) async {
    try {
      final url =
          await Db.client.storage.from('proofs').createSignedUrl(path, 300);
      if (!context.mounted) return;
      showDialog(
        context: context,
        builder: (_) => Dialog(
          child: InteractiveViewer(
            child: Image.network(url,
                errorBuilder: (_, __, ___) => const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('Could not load screenshot.'))),
          ),
        ),
      );
    } catch (e) {
      if (context.mounted) showSnack(context, '$e', error: true);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(adminTaskSubmissionsProvider('pending'));
    return async.when(
      loading: () => const LoadingView(),
      error: (e, _) => ErrorView(
          error: e,
          onRetry: () =>
              ref.invalidate(adminTaskSubmissionsProvider('pending'))),
      data: (list) {
        if (list.isEmpty) {
          return const EmptyView(
            icon: Icons.task_alt_rounded,
            title: 'No task submissions',
            subtitle: 'Pending manual-review tasks appear here.',
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: list.length,
          separatorBuilder: (_, __) => const SizedBox(height: 12),
          itemBuilder: (_, i) {
            final c = list[i];
            final proof = (c['proof'] as Map?)?.cast<String, dynamic>() ?? {};
            final method = c['proof_method'] as String? ?? 'none';
            final text = proof['text'] as String?;
            final shot = proof['screenshot_url'] as String?;
            return SectionCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${c['task_title'] ?? 'Task'}',
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 4),
                  Text('${c['user_name'] ?? '—'} · ${c['user_email'] ?? ''}',
                      style: TextStyle(
                          color: context.cx.textSecondary, fontSize: 12)),
                  const SizedBox(height: 10),
                  if (method == 'text') ...[
                    if ((c['proof_instruction'] as String?)?.isNotEmpty ?? false)
                      Text('Asked: ${c['proof_instruction']}',
                          style: TextStyle(
                              color: context.cx.textSecondary, fontSize: 12)),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Expanded(
                          child: Text(text ?? '(no answer)',
                              style:
                                  const TextStyle(fontWeight: FontWeight.w700)),
                        ),
                        if (text != null)
                          IconButton(
                            icon: const Icon(Icons.copy_rounded, size: 18),
                            onPressed: () {
                              Clipboard.setData(ClipboardData(text: text));
                              showSnack(context, 'Copied');
                            },
                          ),
                      ],
                    ),
                  ] else if (method == 'screenshot' && shot != null)
                    OutlinedButton.icon(
                      onPressed: () => _viewScreenshot(context, shot),
                      icon: const Icon(Icons.image_rounded),
                      label: const Text('View screenshot'),
                    ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () =>
                              _review(context, ref, c['id'] as String, false),
                          style: OutlinedButton.styleFrom(
                              foregroundColor: AppColors.danger,
                              side: const BorderSide(color: AppColors.danger)),
                          icon: const Icon(Icons.close_rounded),
                          label: const Text('Reject'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: () =>
                              _review(context, ref, c['id'] as String, true),
                          icon: const Icon(Icons.check_rounded),
                          label: Text('Approve +${c['reward'] ?? 0}'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}
