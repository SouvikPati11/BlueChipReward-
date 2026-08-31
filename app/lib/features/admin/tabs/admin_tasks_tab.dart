import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/common.dart';
import '../../../core/widgets/state_views.dart';
import '../../../providers/repositories.dart';
import '../admin_providers.dart';

class AdminTasksTab extends ConsumerWidget {
  const AdminTasksTab({super.key});

  Future<void> _review(
      BuildContext context, WidgetRef ref, String id, bool approve) async {
    try {
      await ref.read(adminRepositoryProvider).reviewTask(id, approve);
      ref.invalidate(adminTasksProvider);
      ref.invalidate(adminStatsProvider);
      if (context.mounted) {
        showSnack(context, approve ? 'Approved' : 'Rejected');
      }
    } catch (e) {
      if (context.mounted) showSnack(context, '$e', error: true);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(adminTasksProvider);
    return async.when(
      loading: () => const LoadingView(),
      error: (e, _) =>
          ErrorView(error: e, onRetry: () => ref.invalidate(adminTasksProvider)),
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
            final task = (c['tasks'] as Map?)?.cast<String, dynamic>();
            return SectionCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(task?['title'] ?? 'Task',
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 4),
                  Text('User: ${c['user_id']}',
                      style: TextStyle(
                          color: AppColors.textSecondary, fontSize: 12)),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () =>
                              _review(context, ref, c['id'] as String, false),
                          style: OutlinedButton.styleFrom(
                              foregroundColor: AppColors.danger,
                              side:
                                  const BorderSide(color: AppColors.danger)),
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
                          label: Text('Approve +${task?['reward'] ?? 0}'),
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
