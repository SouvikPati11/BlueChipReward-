import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/state_views.dart';
import '../../providers/data_providers.dart';
import '../home/widgets/balance_hero.dart';

class WalletScreen extends ConsumerWidget {
  const WalletScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final walletAsync = ref.watch(walletProvider);
    final txAsync = ref.watch(transactionsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Wallet'),
        actions: [
          IconButton(
            onPressed: () => context.push('/withdrawals'),
            icon: const Icon(Icons.history_rounded),
            tooltip: 'Withdrawal history',
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(walletProvider);
            ref.invalidate(transactionsProvider);
            await ref.read(transactionsProvider.future);
          },
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              walletAsync.when(
                data: (w) => BalanceHero(wallet: w, showActions: false),
                loading: () =>
                    const SizedBox(height: 200, child: LoadingView()),
                error: (e, _) => SizedBox(
                    height: 200,
                    child: ErrorView(
                        error: e,
                        onRetry: () => ref.invalidate(walletProvider))),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: () => context.push('/withdraw'),
                icon: const Icon(Icons.account_balance_wallet_rounded),
                label: const Text('Request withdrawal'),
              ),
              const SizedBox(height: 24),
              const Text('Transaction history',
                  style:
                      TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              txAsync.when(
                loading: () => const Padding(
                    padding: EdgeInsets.all(24), child: LoadingView()),
                error: (e, _) => ErrorView(
                    error: e,
                    onRetry: () => ref.invalidate(transactionsProvider)),
                data: (list) {
                  if (list.isEmpty) {
                    return const EmptyView(
                      icon: Icons.receipt_long_rounded,
                      title: 'No transactions yet',
                      subtitle: 'Your earnings and withdrawals appear here.',
                    );
                  }
                  return Column(
                    children: [
                      for (final tx in list)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: CircleAvatar(
                            backgroundColor: (tx.isCredit
                                    ? AppColors.success
                                    : AppColors.danger)
                                .withOpacity(.12),
                            child: Icon(
                                tx.isCredit
                                    ? Icons.arrow_downward_rounded
                                    : Icons.arrow_upward_rounded,
                                color: tx.isCredit
                                    ? AppColors.success
                                    : AppColors.danger),
                          ),
                          title: Text(Fmt.txLabel(tx.type),
                              style: const TextStyle(
                                  fontWeight: FontWeight.w700)),
                          subtitle: Text(Fmt.dateTime(tx.createdAt)),
                          trailing: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text('${tx.isCredit ? '+' : ''}${tx.amount}',
                                  style: TextStyle(
                                      fontWeight: FontWeight.w800,
                                      color: tx.isCredit
                                          ? AppColors.success
                                          : AppColors.danger)),
                              Text('bal ${Fmt.points(tx.balanceAfter)}',
                                  style: const TextStyle(
                                      fontSize: 11,
                                      color: AppColors.textSecondary)),
                            ],
                          ),
                        ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
