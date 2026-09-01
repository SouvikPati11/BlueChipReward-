import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:bluechip_rewards/core/theme/app_colors.dart';
import 'package:bluechip_rewards/core/theme/app_palette.dart';
import '../../../core/supabase/supabase_client.dart';
import '../../../core/widgets/common.dart';
import '../../../core/widgets/state_views.dart';
import '../../../providers/repositories.dart';
import '../admin_providers.dart';

/// Manual invite-milestone claims awaiting screenshot-proof review.
class AdminInviteClaimsTab extends ConsumerWidget {
  const AdminInviteClaimsTab({super.key});

  Future<void> _resolve(
      BuildContext context, WidgetRef ref, String id, bool approve) async {
    try {
      await ref.read(adminRepositoryProvider).resolveInviteClaim(id, approve);
      ref.invalidate(adminInviteClaimsProvider('pending'));
      if (context.mounted) {
        showSnack(context, approve ? 'Approved & paid' : 'Rejected');
      }
    } catch (e) {
      if (context.mounted) showSnack(context, '$e', error: true);
    }
  }

  Future<void> _viewProof(BuildContext context, String path) async {
    try {
      // Private bucket: generate a short-lived signed URL to preview.
      final url = await Db.client.storage
          .from('proofs')
          .createSignedUrl(path, 300);
      if (!context.mounted) return;
      showDialog(
        context: context,
        builder: (_) => Dialog(
          child: InteractiveViewer(
            child: Image.network(url,
                errorBuilder: (_, __, ___) => const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('Could not load proof image.'))),
          ),
        ),
      );
    } catch (e) {
      if (context.mounted) showSnack(context, '$e', error: true);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(adminInviteClaimsProvider('pending'));
    return async.when(
      loading: () => const LoadingView(),
      error: (e, _) => ErrorView(
          error: e,
          onRetry: () => ref.invalidate(adminInviteClaimsProvider('pending'))),
      data: (list) {
        if (list.isEmpty) {
          return const EmptyView(
            icon: Icons.emoji_events_outlined,
            title: 'No pending claims',
            subtitle: 'Manual invite-milestone claims will appear here.',
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: list.length,
          separatorBuilder: (_, __) => const SizedBox(height: 12),
          itemBuilder: (_, i) {
            final c = list[i];
            final proofUrl = (c['proof'] as Map?)?['screenshot_url'] as String?;
            final verified = (c['invite_count'] as num?)?.toInt() ?? 0;
            final threshold = (c['threshold'] as num?)?.toInt() ?? 0;
            return SectionCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                            '${c['user_name'] ?? '—'} · ${c['user_email'] ?? ''}',
                            style:
                                const TextStyle(fontWeight: FontWeight.w800)),
                      ),
                      BcpAmount((c['reward'] as num?)?.toInt() ?? 0,
                          showSign: true),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                      'Milestone: invite $threshold · Verified referrals: $verified',
                      style: TextStyle(color: context.cx.textSecondary)),
                  if (verified >= threshold)
                    const Padding(
                      padding: EdgeInsets.only(top: 4),
                      child: Text('Server confirms threshold reached',
                          style: TextStyle(
                              color: AppColors.success,
                              fontWeight: FontWeight.w600,
                              fontSize: 12)),
                    ),
                  const SizedBox(height: 10),
                  if (proofUrl != null)
                    OutlinedButton.icon(
                      onPressed: () => _viewProof(context, proofUrl),
                      icon: const Icon(Icons.image_rounded),
                      label: const Text('View proof screenshot'),
                    ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => _resolve(
                              context, ref, c['id'] as String, false),
                          icon: const Icon(Icons.close_rounded),
                          label: const Text('Reject'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: () =>
                              _resolve(context, ref, c['id'] as String, true),
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
}
