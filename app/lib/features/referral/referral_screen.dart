import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/config/constants.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/common.dart';
import '../../core/widgets/state_views.dart';
import '../../models/wallet_models.dart';
import '../../providers/data_providers.dart';
import 'package:bluechip_rewards/core/theme/app_palette.dart';

class ReferralScreen extends ConsumerWidget {
  const ReferralScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final statsAsync = ref.watch(referralStatsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Refer & Earn')),
      body: SafeArea(
        top: false,
        child: statsAsync.when(
          loading: () => const LoadingView(),
          error: (e, _) => ErrorView(
              error: e, onRetry: () => ref.invalidate(referralStatsProvider)),
          data: (stats) {
            final link = '${K.referralBaseUrl}${stats.referralCode}';
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                SectionCard(
                  gradient: AppColors.heroGradient,
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    children: [
                      const Icon(Icons.groups_rounded,
                          color: Colors.white, size: 44),
                      const SizedBox(height: 12),
                      const Text('Invite friends, earn together',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 20,
                              fontWeight: FontWeight.w800)),
                      const SizedBox(height: 6),
                      Text(
                          stats.perReferralReward > 0
                              ? 'Earn ${stats.perReferralReward} BCP for every friend who joins with your code.'
                              : 'Earn BCP for every friend who joins with your code.',
                          textAlign: TextAlign.center,
                          style:
                              TextStyle(color: Colors.white.withValues(alpha: .9))),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                        child: _StatCard(
                            label: 'Total referrals',
                            value: '${stats.totalReferrals}',
                            icon: Icons.person_add_rounded)),
                    const SizedBox(width: 12),
                    Expanded(
                        child: _StatCard(
                            label: 'Total BCP earned',
                            value: Fmt.points(stats.totalEarned),
                            icon: Icons.savings_rounded)),
                  ],
                ),
                if (stats.levels.length > 1) ...[
                  const SizedBox(height: 16),
                  _LevelBreakdown(levels: stats.levels),
                ],
                const SizedBox(height: 16),
                SectionCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Your referral code',
                          style: TextStyle(
                              color: context.cx.textSecondary, fontSize: 13)),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 14),
                              decoration: BoxDecoration(
                                color: context.cx.surfaceAlt,
                                borderRadius: BorderRadius.circular(12),
                                border:
                                    Border.all(color: context.cx.border),
                              ),
                              child: Text(stats.referralCode,
                                  style: const TextStyle(
                                      fontSize: 20,
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: 2)),
                            ),
                          ),
                          const SizedBox(width: 10),
                          IconButton.filledTonal(
                            onPressed: () {
                              Clipboard.setData(
                                  ClipboardData(text: stats.referralCode));
                              showSnack(context, 'Code copied');
                            },
                            icon: const Icon(Icons.copy_rounded),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: () => SharePlus.instance.share(
                              ShareParams(
                                  text:
                                      'Join me on ${K.appName} and earn rewards! Use my code ${stats.referralCode} or tap: $link')),
                          icon: const Icon(Icons.share_rounded),
                          label: const Text('Share invite'),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: () => context.push('/refer/milestones'),
                  child: SectionCard(
                    child: Row(
                      children: [
                        Container(
                          width: 46,
                          height: 46,
                          decoration: BoxDecoration(
                            color: AppColors.gold.withValues(alpha: .14),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: const Icon(Icons.emoji_events_rounded,
                              color: AppColors.gold),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('Invite milestones',
                                  style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w800)),
                              Text('Earn bonus BCP at 5, 10, 20 invites.',
                                  style: TextStyle(
                                      color: context.cx.textSecondary,
                                      fontSize: 13)),
                            ],
                          ),
                        ),
                        const Icon(Icons.arrow_forward_ios_rounded, size: 16),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                const Text('Recent referrals',
                    style:
                        TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                const SizedBox(height: 8),
                if (stats.recent.isEmpty)
                  const EmptyView(
                    icon: Icons.person_search_rounded,
                    title: 'No referrals yet',
                    subtitle: 'Share your code to start earning.',
                  )
                else
                  for (final r in stats.recent)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const CircleAvatar(
                        backgroundColor: Color(0x1416A34A),
                        child: Icon(Icons.person_rounded,
                            color: AppColors.success),
                      ),
                      title: Text(
                          r.level > 1 ? 'Level ${r.level} referral' : 'Referred user',
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: Text(Fmt.timeAgo(r.createdAt)),
                      trailing: Text('+${r.reward}',
                          style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              color: AppColors.success)),
                    ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _LevelBreakdown extends StatelessWidget {
  final List<ReferralLevel> levels;
  const _LevelBreakdown({required this.levels});

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Your referral network',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text('You earn on multiple levels of referrals.',
              style: TextStyle(color: context.cx.textSecondary, fontSize: 13)),
          const SizedBox(height: 14),
          for (final l in levels) ...[
            Row(
              children: [
                CircleAvatar(
                  radius: 16,
                  backgroundColor: AppColors.primary.withValues(alpha: .12),
                  child: Text('L${l.level}',
                      style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          color: AppColors.primary)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                          'Level ${l.level} · ${l.rewardLabel}${l.percentEnabled ? ' (≈${l.reward} BCP)' : ''}',
                          style:
                              const TextStyle(fontWeight: FontWeight.w700)),
                      Text(
                          '${l.count} referral${l.count == 1 ? '' : 's'}${l.enabled ? '' : ' · disabled'}',
                          style: TextStyle(
                              color: context.cx.textSecondary, fontSize: 12)),
                    ],
                  ),
                ),
                Text('+${Fmt.points(l.earnings)}',
                    style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        color: AppColors.success)),
              ],
            ),
            if (l.level != levels.last.level)
              Divider(height: 20, color: context.cx.border),
          ],
        ],
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  const _StatCard(
      {required this.label, required this.value, required this.icon});

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: AppColors.primary),
          const SizedBox(height: 10),
          Text(value,
              style: const TextStyle(
                  fontSize: 24, fontWeight: FontWeight.w900)),
          Text(label, style: TextStyle(color: context.cx.textSecondary)),
        ],
      ),
    );
  }
}
