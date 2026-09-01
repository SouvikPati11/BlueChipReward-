import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/common.dart';
import '../../../core/widgets/state_views.dart';
import '../admin_providers.dart';
import 'package:bluechip_rewards/core/theme/app_palette.dart';

class AdminDashboardTab extends ConsumerWidget {
  const AdminDashboardTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(adminStatsProvider);
    return async.when(
      loading: () => const LoadingView(),
      error: (e, _) =>
          ErrorView(error: e, onRetry: () => ref.invalidate(adminStatsProvider)),
      data: (s) {
        int n(String k) => (s[k] as num?)?.toInt() ?? 0;
        final cards = [
          _M('Users', Fmt.points(n('users')), Icons.people_rounded,
              AppColors.primary),
          _M('Active', Fmt.points(n('active_users')), Icons.verified_rounded,
              AppColors.success),
          _M('BCP in circulation', Fmt.points(n('total_balance')),
              Icons.monetization_on_rounded, AppColors.gold),
          _M('Total earned', Fmt.points(n('total_earned')),
              Icons.trending_up_rounded, AppColors.info),
          _M('Pending withdrawals', Fmt.points(n('pending_withdrawals')),
              Icons.pending_actions_rounded, AppColors.warning),
          _M('Pending tasks', Fmt.points(n('pending_tasks')),
              Icons.task_rounded, Color(0xFF8B5CF6)),
          _M('Active mining', Fmt.points(n('active_mining')),
              Icons.bolt_rounded, AppColors.danger),
          _M('Withdrawal amount', Fmt.points(n('pending_withdrawal_amount')),
              Icons.account_balance_wallet_rounded, AppColors.primaryDark),
        ];
        return RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(adminStatsProvider);
            await ref.read(adminStatsProvider.future);
          },
          child: GridView.count(
            crossAxisCount: 2,
            padding: const EdgeInsets.all(16),
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 1.35,
            children: [
              for (final c in cards)
                SectionCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(c.icon, color: c.color),
                      const SizedBox(height: 8),
                      Text(c.value,
                          style: const TextStyle(
                              fontSize: 22, fontWeight: FontWeight.w900)),
                      Text(c.label,
                          maxLines: 2,
                          style:
                              TextStyle(color: context.cx.textSecondary, fontSize: 13)),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _M {
  final String label;
  final String value;
  final IconData icon;
  final Color color;
  const _M(this.label, this.value, this.icon, this.color);
}
