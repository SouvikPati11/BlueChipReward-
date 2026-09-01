import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/common.dart';
import '../../core/widgets/state_views.dart';
import '../../models/profile.dart';
import '../../providers/data_providers.dart';
import '../earn/earn_methods.dart';
import 'widgets/balance_hero.dart';
import 'package:bluechip_rewards/core/theme/app_palette.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final walletAsync = ref.watch(walletProvider);
    final profileAsync = ref.watch(profileProvider);
    final dailyAsync = ref.watch(dailyStatusProvider);

    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(walletProvider);
            ref.invalidate(profileProvider);
            ref.invalidate(dailyStatusProvider);
            await ref.read(walletProvider.future);
          },
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              _TopBar(profile: profileAsync.valueOrNull),
              const SizedBox(height: 16),
              walletAsync.when(
                data: (w) => BalanceHero(
                    wallet: w, profile: profileAsync.valueOrNull),
                loading: () => const SizedBox(
                    height: 220, child: LoadingView()),
                error: (e, _) => SizedBox(
                    height: 220,
                    child: ErrorView(
                        error: e,
                        onRetry: () => ref.invalidate(walletProvider))),
              ),
              const SizedBox(height: 20),
              // Daily reward banner
              dailyAsync.maybeWhen(
                data: (d) => !d.claimedToday
                    ? _DailyBanner(streak: d.currentStreak)
                    : const SizedBox.shrink(),
                orElse: () => const SizedBox.shrink(),
              ),
              const _SectionHeader('Ways to earn'),
              const SizedBox(height: 12),
              _EarnGrid(),
              const SizedBox(height: 24),
              const _SectionHeader('Recent activity'),
              const SizedBox(height: 8),
              const _RecentActivity(),
            ],
          ),
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  final Profile? profile;
  const _TopBar({this.profile});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        CircleAvatar(
          radius: 22,
          backgroundColor: AppColors.primary.withOpacity(.12),
          backgroundImage: (profile?.avatarUrl != null)
              ? NetworkImage(profile!.avatarUrl!)
              : null,
          child: profile?.avatarUrl == null
              ? Text(profile?.initials ?? 'U',
                  style: const TextStyle(
                      color: AppColors.primary, fontWeight: FontWeight.w800))
              : null,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Welcome back',
                  style: TextStyle(color: context.cx.textSecondary, fontSize: 13)),
              Text(profile?.displayName ?? 'Loading…',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w800)),
            ],
          ),
        ),
        IconButton(
          onPressed: () => context.push('/notifications'),
          icon: const Icon(Icons.notifications_none_rounded),
          style: IconButton.styleFrom(
              backgroundColor: context.cx.surface,
              side: BorderSide(color: context.cx.border)),
        ),
      ],
    );
  }
}

class _DailyBanner extends StatelessWidget {
  final int streak;
  const _DailyBanner({required this.streak});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => context.push('/earn/daily'),
        child: SectionCard(
          gradient: AppColors.goldGradient,
          child: Row(
            children: [
              const Icon(Icons.redeem_rounded, color: Colors.white, size: 34),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Daily reward is ready!',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w800)),
                    Text(
                        streak > 0
                            ? 'Keep your $streak-day streak going'
                            : 'Claim your reward now',
                        style: TextStyle(color: Colors.white.withOpacity(.9))),
                  ],
                ),
              ),
              const Icon(Icons.arrow_forward_ios_rounded,
                  color: Colors.white, size: 16),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Text(title,
        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800));
  }
}

class _EarnGrid extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: .86,
      children: [
        for (final m in earnMethods)
          InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: () => context.push(m.route),
            child: SectionCard(
              padding: const EdgeInsets.all(10),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      color: m.color.withOpacity(.12),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(m.icon, color: m.color, size: 24),
                  ),
                  const SizedBox(height: 8),
                  Text(m.title,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      style: const TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w700)),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _RecentActivity extends ConsumerWidget {
  const _RecentActivity();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final txAsync = ref.watch(transactionsProvider);
    return txAsync.when(
      loading: () => const Padding(
          padding: EdgeInsets.all(24), child: LoadingView()),
      error: (e, _) => const SizedBox.shrink(),
      data: (list) {
        if (list.isEmpty) {
          return const EmptyView(
            icon: Icons.receipt_long_rounded,
            title: 'No activity yet',
            subtitle: 'Start earning to see your history here.',
          );
        }
        return Column(
          children: [
            for (final tx in list.take(5))
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
                      color:
                          tx.isCredit ? AppColors.success : AppColors.danger),
                ),
                title: Text(Fmt.txLabel(tx.type),
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text(Fmt.timeAgo(tx.createdAt)),
                trailing: Text(
                    '${tx.isCredit ? '+' : ''}${tx.amount}',
                    style: TextStyle(
                        fontWeight: FontWeight.w800,
                        color: tx.isCredit
                            ? AppColors.success
                            : AppColors.danger)),
              ),
          ],
        );
      },
    );
  }
}
