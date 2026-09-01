import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/config/constants.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/common.dart';
import '../../core/widgets/state_views.dart';
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
                          'Earn BCP for every friend who joins with your code.',
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
                            label: 'Referrals',
                            value: '${stats.totalReferrals}',
                            icon: Icons.person_add_rounded)),
                    const SizedBox(width: 12),
                    Expanded(
                        child: _StatCard(
                            label: 'BCP earned',
                            value: Fmt.points(stats.totalEarned),
                            icon: Icons.savings_rounded)),
                  ],
                ),
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
                          onPressed: () => Share.share(
                              'Join me on ${K.appName} and earn rewards! Use my code ${stats.referralCode} or tap: $link'),
                          icon: const Icon(Icons.share_rounded),
                          label: const Text('Share invite'),
                        ),
                      ),
                    ],
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
                      title: const Text('Referred user',
                          style: TextStyle(fontWeight: FontWeight.w700)),
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
