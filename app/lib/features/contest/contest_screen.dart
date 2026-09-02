import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/ad_gate.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/common.dart';
import '../../core/widgets/state_views.dart';
import '../../models/earn_models.dart';
import '../../providers/data_providers.dart';
import '../../providers/repositories.dart';
import 'package:bluechip_rewards/core/theme/app_palette.dart';

/// Contests: each user runs their own independent cycle (start → progress →
/// claim). Progress + deadlines are server-authoritative.
class ContestScreen extends ConsumerStatefulWidget {
  const ContestScreen({super.key});

  @override
  ConsumerState<ContestScreen> createState() => _ContestScreenState();
}

class _ContestScreenState extends ConsumerState<ContestScreen> {
  String? _busyId;

  Future<void> _start(Contest c) async {
    setState(() => _busyId = c.id);
    try {
      await ref.read(earnRepositoryProvider).startContest(c.id);
      ref.invalidate(contestsProvider);
    } catch (e) {
      if (mounted) showSnack(context, '$e', error: true);
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<void> _claim(Contest c) async {
    final p = c.participation!;
    setState(() => _busyId = c.id);
    try {
      String? nonce;
      if (c.requiresAd) nonce = await runRewardedGate(ref, 'contest');
      await ref
          .read(earnRepositoryProvider)
          .claimContest(p.id, nonce: nonce);
      ref.invalidate(contestsProvider);
      if (mounted) {
        showSnack(context,
            'Claim submitted. You\'ll be rewarded once an admin approves it.');
      }
    } catch (e) {
      if (mounted) showSnack(context, '$e', error: true);
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(contestsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Contests')),
      body: SafeArea(
        top: false,
        child: async.when(
          loading: () => const LoadingView(),
          error: (e, _) => ErrorView(
              error: e, onRetry: () => ref.invalidate(contestsProvider)),
          data: (list) {
            if (list.isEmpty) {
              return const EmptyView(
                icon: Icons.emoji_events_outlined,
                title: 'No contests right now',
                subtitle: 'Check back soon for new challenges.',
              );
            }
            return RefreshIndicator(
              onRefresh: () async {
                ref.invalidate(contestsProvider);
                await ref.read(contestsProvider.future);
              },
              child: ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: list.length,
                separatorBuilder: (_, __) => const SizedBox(height: 12),
                itemBuilder: (_, i) => _ContestCard(
                  contest: list[i],
                  busy: _busyId == list[i].id,
                  onStart: () => _start(list[i]),
                  onClaim: () => _claim(list[i]),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _ContestCard extends StatelessWidget {
  final Contest contest;
  final bool busy;
  final VoidCallback onStart;
  final VoidCallback onClaim;
  const _ContestCard(
      {required this.contest,
      required this.busy,
      required this.onStart,
      required this.onClaim});

  @override
  Widget build(BuildContext context) {
    final c = contest;
    final p = c.participation;
    final progress = p == null
        ? 0.0
        : (c.targetValue == 0 ? 1.0 : (p.progress / c.targetValue).clamp(0.0, 1.0));

    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
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
                    Text(c.name,
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w800)),
                    Text('Target: ${c.targetValue} ${c.targetLabel}',
                        style: TextStyle(
                            color: context.cx.textSecondary, fontSize: 12)),
                  ],
                ),
              ),
              BcpAmount(c.reward, showSign: true),
            ],
          ),
          if (c.rules?.isNotEmpty ?? false) ...[
            const SizedBox(height: 8),
            Text(c.rules!,
                style: TextStyle(color: context.cx.textSecondary, fontSize: 13)),
          ],
          const SizedBox(height: 14),
          if (p == null)
            _pill(context, 'Duration: ${_durationText(c.durationHours)}')
          else ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 8,
                backgroundColor: context.cx.surfaceAlt,
                valueColor: const AlwaysStoppedAnimation(AppColors.primary),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Text('${p.progress} / ${c.targetValue}',
                    style: TextStyle(
                        color: context.cx.textSecondary, fontSize: 12)),
                const Spacer(),
                if (p.endsAt != null && p.state == 'active')
                  Text('Ends ${Fmt.timeAgo(p.endsAt!)}',
                      style: TextStyle(
                          color: context.cx.textSecondary, fontSize: 12)),
              ],
            ),
          ],
          const SizedBox(height: 12),
          _action(context),
        ],
      ),
    );
  }

  String _durationText(int hours) =>
      hours % 24 == 0 ? '${hours ~/ 24} days' : '$hours hours';

  Widget _pill(BuildContext context, String text) => Align(
        alignment: Alignment.centerLeft,
        child: Pill(text, color: AppColors.primary),
      );

  Widget _action(BuildContext context) {
    final p = contest.participation;
    Widget btn(String label, VoidCallback? onTap, {Color? color}) => SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: busy ? null : onTap,
            style: color != null
                ? ElevatedButton.styleFrom(backgroundColor: color)
                : null,
            child: busy
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : Text(label),
          ),
        );

    if (p == null) return btn('Start contest', onStart);
    switch (p.state) {
      case 'claim_pending':
        return const Pill('Claim under review',
            color: AppColors.warning, icon: Icons.hourglass_bottom_rounded);
      case 'completed':
        return const Pill('Completed',
            color: AppColors.success, icon: Icons.check_rounded);
      case 'expired':
        return btn('Start again', onStart);
      case 'rejected':
        return btn('Start again', onStart);
      default:
        if (p.claimable) {
          return btn(
              contest.requiresAd ? 'Watch ad & claim' : 'Claim reward', onClaim,
              color: AppColors.gold);
        }
        return const Pill('In progress',
            color: AppColors.primary, icon: Icons.timelapse_rounded);
    }
  }
}
