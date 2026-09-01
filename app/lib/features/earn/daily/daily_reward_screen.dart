import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/common.dart';
import '../../../core/widgets/state_views.dart';
import '../../../providers/data_providers.dart';
import '../../../providers/repositories.dart';
import 'package:bluechip_rewards/core/theme/app_palette.dart';

class DailyRewardScreen extends ConsumerStatefulWidget {
  const DailyRewardScreen({super.key});

  @override
  ConsumerState<DailyRewardScreen> createState() => _DailyRewardScreenState();
}

class _DailyRewardScreenState extends ConsumerState<DailyRewardScreen> {
  bool _claiming = false;

  Future<void> _claim() async {
    setState(() => _claiming = true);
    try {
      final res = await ref.read(earnRepositoryProvider).claimDaily();
      ref.invalidate(dailyStatusProvider);
      ref.invalidate(walletProvider);
      ref.invalidate(transactionsProvider);
      if (mounted) {
        await showRewardDialog(context,
            amount: (res['amount'] as num).toInt(),
            title: 'Daily reward claimed!');
      }
    } catch (e) {
      if (mounted) showSnack(context, '$e', error: true);
    } finally {
      if (mounted) setState(() => _claiming = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final statusAsync = ref.watch(dailyStatusProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Daily Reward')),
      body: SafeArea(
        top: false,
        child: statusAsync.when(
          loading: () => const LoadingView(),
          error: (e, _) => ErrorView(
              error: e, onRetry: () => ref.invalidate(dailyStatusProvider)),
          data: (status) {
            final claimed = status.claimedToday;
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                SectionCard(
                  gradient: AppColors.heroGradient,
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    children: [
                      Container(
                        width: 96,
                        height: 96,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: .16),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                            claimed
                                ? Icons.check_circle_rounded
                                : Icons.redeem_rounded,
                            color: Colors.white,
                            size: 52),
                      ),
                      const SizedBox(height: 18),
                      Text(
                          claimed
                              ? 'Already claimed today'
                              : 'Your reward is ready!',
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 20,
                              fontWeight: FontWeight.w800)),
                      const SizedBox(height: 6),
                      Text(
                        claimed
                            ? 'Come back tomorrow to keep your streak.'
                            : 'Claim now and build your streak.',
                        textAlign: TextAlign.center,
                        style:
                            TextStyle(color: Colors.white.withValues(alpha: .85)),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                _StreakRow(current: status.currentStreak),
                const SizedBox(height: 24),
                ElevatedButton.icon(
                  onPressed: (claimed || _claiming) ? null : _claim,
                  icon: _claiming
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2.2, color: Colors.white))
                      : const Icon(Icons.card_giftcard_rounded),
                  label: Text(claimed ? 'Claimed' : 'Claim reward'),
                ),
                const SizedBox(height: 12),
                Text(
                  'Rewards grow with consecutive daily claims. Miss a day and the streak resets.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: context.cx.textSecondary, fontSize: 13),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _StreakRow extends StatelessWidget {
  final int current;
  const _StreakRow({required this.current});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: List.generate(7, (i) {
        final day = i + 1;
        final done = day <= current;
        return Column(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: done ? AppColors.gold : context.cx.surfaceAlt,
                shape: BoxShape.circle,
                border: Border.all(
                    color: done ? AppColors.gold : context.cx.border),
              ),
              child: Icon(
                  done ? Icons.check_rounded : Icons.circle_outlined,
                  size: 18,
                  color: done ? Colors.white : context.cx.textSecondary),
            ),
            const SizedBox(height: 6),
            Text('D$day',
                style: TextStyle(
                    fontSize: 11,
                    color: context.cx.textSecondary,
                    fontWeight: FontWeight.w600)),
          ],
        );
      }),
    );
  }
}
