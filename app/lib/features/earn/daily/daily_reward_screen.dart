import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/ad_gate.dart';
import '../../../core/widgets/banner_ad_bar.dart';
import '../../../core/widgets/common.dart';
import '../../../core/widgets/state_views.dart';
import '../../../models/earn_models.dart';
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
      // Rewarded-ad gated: obtain a completed-ad nonce first (throws if the ad
      // isn't watched to completion), then claim.
      final nonce = await runRewardedGate(ref, 'daily');
      final res =
          await ref.read(earnRepositoryProvider).claimDaily(nonce: nonce);
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
      bottomNavigationBar: const BannerAdBar(),
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
                _DayWiseRow(status: status),
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
                  label: Text(claimed ? 'Claimed' : 'Watch ad & claim'),
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

/// Day-wise reward strip: shows each day's configured BCP amount, marks days
/// already claimed in the current cycle, and highlights the next reward.
class _DayWiseRow extends StatelessWidget {
  final DailyStatus status;
  const _DayWiseRow({required this.status});

  @override
  Widget build(BuildContext context) {
    final days = status.days.isNotEmpty
        ? status.days
        : const [10, 20, 30, 40, 50, 70, 100];
    // Position within the current 7-day cycle (0-based) already completed.
    final completed = status.currentStreak % days.length;
    // The next day to claim (0-based index in the cycle).
    final nextIdx = status.claimedToday
        ? -1
        : (status.nextStreak - 1) % days.length;

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      alignment: WrapAlignment.center,
      children: [
        for (var i = 0; i < days.length; i++)
          _DayChip(
            day: i + 1,
            amount: days[i],
            done: status.claimedToday
                ? i < ((status.currentStreak - 1) % days.length) + 1
                : i < completed,
            isNext: i == nextIdx,
          ),
      ],
    );
  }
}

class _DayChip extends StatelessWidget {
  final int day;
  final int amount;
  final bool done;
  final bool isNext;
  const _DayChip(
      {required this.day,
      required this.amount,
      required this.done,
      required this.isNext});

  @override
  Widget build(BuildContext context) {
    final bg = done
        ? AppColors.gold
        : isNext
            ? AppColors.primary.withValues(alpha: .12)
            : context.cx.surfaceAlt;
    final border = isNext ? AppColors.primary : context.cx.border;
    return Container(
      width: 64,
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: border, width: isNext ? 1.6 : 1),
      ),
      child: Column(
        children: [
          Text('Day $day',
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: done ? Colors.white : context.cx.textSecondary)),
          const SizedBox(height: 4),
          if (done)
            const Icon(Icons.check_rounded, size: 16, color: Colors.white)
          else
            Text('$amount',
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w900,
                    color: isNext ? AppColors.primary : context.cx.textPrimary)),
          Text('BCP',
              style: TextStyle(
                  fontSize: 9,
                  color: done ? Colors.white70 : context.cx.textSecondary)),
        ],
      ),
    );
  }
}
