import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/common.dart';
import '../../../core/widgets/state_views.dart';
import '../../../models/earn_models.dart';
import '../../../providers/data_providers.dart';
import '../../../providers/repositories.dart';
import 'package:bluechip_rewards/core/theme/app_palette.dart';

/// Invite milestones: earn bonus BCP for reaching referral counts (5/10/20…).
/// Auto-verify milestones credit instantly once reached; manual ones require a
/// screenshot proof that an admin reviews.
class InviteMilestonesScreen extends ConsumerStatefulWidget {
  const InviteMilestonesScreen({super.key});

  @override
  ConsumerState<InviteMilestonesScreen> createState() =>
      _InviteMilestonesScreenState();
}

class _InviteMilestonesScreenState
    extends ConsumerState<InviteMilestonesScreen> {
  String? _busyId;

  Future<void> _claim(InviteMilestone m) async {
    setState(() => _busyId = m.id);
    try {
      final repo = ref.read(earnRepositoryProvider);
      String? proofPath;
      if (!m.autoVerify) {
        final picker = ImagePicker();
        final picked = await picker.pickImage(
            source: ImageSource.gallery, imageQuality: 70, maxWidth: 1600);
        if (picked == null) {
          setState(() => _busyId = null);
          return;
        }
        final bytes = await picked.readAsBytes();
        final ext = picked.name.contains('.')
            ? picked.name.split('.').last.toLowerCase()
            : 'jpg';
        proofPath = await repo.uploadProof(m.id, bytes, ext: ext);
      }
      final res = await repo.claimInviteMilestone(m.id, proofPath: proofPath);
      ref.invalidate(inviteMilestonesProvider);
      ref.invalidate(walletProvider);
      ref.invalidate(transactionsProvider);
      if (!mounted) return;
      final state = res['state'] as String? ?? '';
      if (state == 'credited') {
        await showRewardDialog(context,
            amount: m.reward, title: 'Milestone reached!');
      } else if (state == 'pending') {
        showSnack(context,
            'Proof submitted. You\'ll be rewarded once an admin approves it.');
      }
    } catch (e) {
      if (mounted) showSnack(context, _friendly('$e'), error: true);
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  String _friendly(String e) {
    if (e.contains('MILESTONE_NOT_REACHED')) {
      return 'You haven\'t reached this milestone yet.';
    }
    if (e.contains('PROOF_REQUIRED')) return 'A proof screenshot is required.';
    return e;
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(inviteMilestonesProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Invite milestones')),
      body: SafeArea(
        top: false,
        child: async.when(
          loading: () => const LoadingView(),
          error: (e, _) => ErrorView(
              error: e,
              onRetry: () => ref.invalidate(inviteMilestonesProvider)),
          data: (data) {
            if (data.milestones.isEmpty) {
              return const EmptyView(
                icon: Icons.emoji_events_outlined,
                title: 'No milestones yet',
                subtitle: 'Invite milestones will appear here soon.',
              );
            }
            return RefreshIndicator(
              onRefresh: () async {
                ref.invalidate(inviteMilestonesProvider);
                await ref.read(inviteMilestonesProvider.future);
              },
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  SectionCard(
                    gradient: AppColors.heroGradient,
                    padding: const EdgeInsets.all(22),
                    child: Row(
                      children: [
                        const Icon(Icons.groups_2_rounded,
                            color: Colors.white, size: 40),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('${data.inviteCount} invites',
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 24,
                                      fontWeight: FontWeight.w900)),
                              Text('Invite friends to unlock bonus rewards.',
                                  style: TextStyle(
                                      color:
                                          Colors.white.withValues(alpha: .9))),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  for (final m in data.milestones) ...[
                    _MilestoneCard(
                      m: m,
                      inviteCount: data.inviteCount,
                      busy: _busyId == m.id,
                      onClaim: () => _claim(m),
                    ),
                    const SizedBox(height: 12),
                  ],
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _MilestoneCard extends StatelessWidget {
  final InviteMilestone m;
  final int inviteCount;
  final bool busy;
  final VoidCallback onClaim;
  const _MilestoneCard({
    required this.m,
    required this.inviteCount,
    required this.busy,
    required this.onClaim,
  });

  @override
  Widget build(BuildContext context) {
    final progress =
        m.threshold == 0 ? 1.0 : (inviteCount / m.threshold).clamp(0.0, 1.0);
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
                    Text('Invite ${m.threshold} friends',
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w800)),
                    Text(
                        m.autoVerify
                            ? 'Auto-verified'
                            : 'Requires screenshot proof',
                        style: TextStyle(
                            color: context.cx.textSecondary, fontSize: 12)),
                  ],
                ),
              ),
              BcpAmount(m.reward, showSign: true),
            ],
          ),
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 8,
              backgroundColor: context.cx.surfaceAlt,
              valueColor:
                  const AlwaysStoppedAnimation(AppColors.primary),
            ),
          ),
          const SizedBox(height: 6),
          Text('${inviteCount.clamp(0, m.threshold)} / ${m.threshold}',
              style: TextStyle(color: context.cx.textSecondary, fontSize: 12)),
          const SizedBox(height: 12),
          _action(context),
        ],
      ),
    );
  }

  Widget _action(BuildContext context) {
    if (m.isCredited) {
      return const Pill('Reward claimed',
          color: AppColors.success, icon: Icons.check_rounded);
    }
    if (m.isPending) {
      return const Pill('Awaiting approval',
          color: AppColors.warning, icon: Icons.hourglass_bottom_rounded);
    }
    if (m.isRejected) {
      return const Pill('Rejected',
          color: AppColors.danger, icon: Icons.close_rounded);
    }
    final canClaim = m.claimable;
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: (!canClaim || busy) ? null : onClaim,
        style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(46)),
        icon: busy
            ? const SizedBox(
                height: 18,
                width: 18,
                child:
                    CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
            : Icon(m.autoVerify
                ? Icons.redeem_rounded
                : Icons.upload_file_rounded),
        label: Text(canClaim
            ? (m.autoVerify ? 'Claim reward' : 'Upload proof & claim')
            : 'Locked'),
      ),
    );
  }
}
