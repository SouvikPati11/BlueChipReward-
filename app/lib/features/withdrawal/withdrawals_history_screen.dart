import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/common.dart';
import '../../core/widgets/state_views.dart';
import '../../providers/data_providers.dart';
import 'package:bluechip_rewards/core/theme/app_palette.dart';

class WithdrawalsHistoryScreen extends ConsumerWidget {
  const WithdrawalsHistoryScreen({super.key});

  Color _statusColor(String s) {
    switch (s) {
      case 'paid':
        return AppColors.success;
      case 'approved':
        return AppColors.info;
      case 'rejected':
        return AppColors.danger;
      default:
        return AppColors.warning;
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(withdrawalsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Withdrawals')),
      body: SafeArea(
        top: false,
        child: async.when(
          loading: () => const LoadingView(),
          error: (e, _) => ErrorView(
              error: e, onRetry: () => ref.invalidate(withdrawalsProvider)),
          data: (list) {
            if (list.isEmpty) {
              return const EmptyView(
                icon: Icons.account_balance_wallet_rounded,
                title: 'No withdrawals yet',
                subtitle: 'Your withdrawal requests will appear here.',
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
                              color: _statusColor(w.status)),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text('${w.methodKey.toUpperCase()} • ${Fmt.dateTime(w.createdAt)}',
                          style: TextStyle(color: context.cx.textSecondary)),
                      if (w.adminNotes != null &&
                          w.adminNotes!.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: context.cx.surfaceAlt,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text('Note: ${w.adminNotes}',
                              style: const TextStyle(fontSize: 13)),
                        ),
                      ],
                    ],
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}
