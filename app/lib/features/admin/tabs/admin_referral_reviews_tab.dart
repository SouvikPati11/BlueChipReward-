import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:bluechip_rewards/core/theme/app_colors.dart';
import 'package:bluechip_rewards/core/theme/app_palette.dart';
import '../../../core/widgets/common.dart';
import '../../../core/widgets/state_views.dart';
import '../../../providers/repositories.dart';
import '../admin_providers.dart';

/// Suspicious referrals withheld for manual review (self-referral / same device).
class AdminReferralReviewsTab extends ConsumerWidget {
  const AdminReferralReviewsTab({super.key});

  Future<void> _resolve(
      BuildContext context, WidgetRef ref, String id, bool approve) async {
    try {
      await ref.read(adminRepositoryProvider).resolveReferralReview(id, approve);
      ref.invalidate(adminReferralReviewsProvider('pending'));
      if (context.mounted) {
        showSnack(context, approve ? 'Approved & paid' : 'Rejected');
      }
    } catch (e) {
      if (context.mounted) showSnack(context, '$e', error: true);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(adminReferralReviewsProvider('pending'));
    return async.when(
      loading: () => const LoadingView(),
      error: (e, _) => ErrorView(
          error: e,
          onRetry: () =>
              ref.invalidate(adminReferralReviewsProvider('pending'))),
      data: (list) {
        if (list.isEmpty) {
          return const EmptyView(
            icon: Icons.verified_user_rounded,
            title: 'No flagged referrals',
            subtitle: 'Suspicious referrals will appear here for review.',
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: list.length,
          separatorBuilder: (_, __) => const SizedBox(height: 12),
          itemBuilder: (_, i) {
            final r = list[i];
            return SectionCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.report_gmailerrorred_rounded,
                          color: AppColors.warning),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text('Reason: ${r['reason'] ?? 'suspicious'}',
                            style:
                                const TextStyle(fontWeight: FontWeight.w800)),
                      ),
                      Pill('Score ${r['score']}', color: AppColors.warning),
                    ],
                  ),
                  const SizedBox(height: 10),
                  _kv(context, 'Referrer',
                      '${r['referrer_name'] ?? '—'} · ${r['referrer_email'] ?? ''}'),
                  _kv(context, 'Referred',
                      '${r['referred_name'] ?? '—'} · ${r['referred_email'] ?? ''}'),
                  _kv(context, 'Reward', '${r['reward_amount']} BCP (level ${r['level']})'),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => _resolve(
                              context, ref, r['id'] as String, false),
                          icon: const Icon(Icons.close_rounded),
                          label: const Text('Reject'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: () =>
                              _resolve(context, ref, r['id'] as String, true),
                          icon: const Icon(Icons.check_rounded),
                          label: const Text('Approve'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _kv(BuildContext context, String k, String v) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
              width: 78,
              child: Text(k,
                  style: TextStyle(color: context.cx.textSecondary))),
          Expanded(
              child: Text(v,
                  style: const TextStyle(fontWeight: FontWeight.w600))),
        ],
      ),
    );
  }
}
