import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/common.dart';
import '../../../core/widgets/state_views.dart';
import '../../../providers/repositories.dart';
import '../admin_providers.dart';
import 'package:bluechip_rewards/core/theme/app_palette.dart';

class AdminWithdrawalsTab extends ConsumerWidget {
  const AdminWithdrawalsTab({super.key});

  Future<void> _process(BuildContext context, WidgetRef ref, String id,
      String status) async {
    String? notes;
    if (status == 'rejected') {
      notes = await _askNotes(context);
      if (notes == null) return; // cancelled
    }
    try {
      await ref
          .read(adminRepositoryProvider)
          .processWithdrawal(id, status, notes: notes);
      ref.invalidate(adminWithdrawalsProvider);
      ref.invalidate(adminStatsProvider);
      if (context.mounted) showSnack(context, 'Marked $status');
    } catch (e) {
      if (context.mounted) showSnack(context, '$e', error: true);
    }
  }

  Future<String?> _askNotes(BuildContext context) {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Reason for rejection'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(hintText: 'Notes for the user'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.pop(context, ctrl.text.trim()),
              child: const Text('Reject')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(adminWithdrawalsProvider);
    return async.when(
      loading: () => const LoadingView(),
      error: (e, _) => ErrorView(
          error: e, onRetry: () => ref.invalidate(adminWithdrawalsProvider)),
      data: (list) {
        if (list.isEmpty) {
          return const EmptyView(
            icon: Icons.check_circle_rounded,
            title: 'No pending withdrawals',
            subtitle: 'All caught up.',
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: list.length,
          separatorBuilder: (_, __) => const SizedBox(height: 12),
          itemBuilder: (_, i) {
            final w = list[i];
            return SectionCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      BcpAmount(w.amount, size: 18),
                      const Spacer(),
                      Pill(w.status.toUpperCase(),
                          color: w.status == 'approved'
                              ? AppColors.info
                              : AppColors.warning),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text('${w.methodKey.toUpperCase()} • ${Fmt.dateTime(w.createdAt)}',
                      style: TextStyle(color: context.cx.textSecondary)),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    children: [
                      if (w.status == 'pending')
                        OutlinedButton(
                          onPressed: () =>
                              _process(context, ref, w.id, 'approved'),
                          child: const Text('Approve'),
                        ),
                      ElevatedButton(
                        onPressed: () =>
                            _process(context, ref, w.id, 'paid'),
                        style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.success,
                            minimumSize: const Size(90, 42)),
                        child: const Text('Mark paid'),
                      ),
                      OutlinedButton(
                        onPressed: () =>
                            _process(context, ref, w.id, 'rejected'),
                        style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.danger,
                            side:
                                const BorderSide(color: AppColors.danger),
                            minimumSize: const Size(90, 42)),
                        child: const Text('Reject'),
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
