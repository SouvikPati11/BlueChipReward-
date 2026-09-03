import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:bluechip_rewards/core/theme/app_colors.dart';
import 'package:bluechip_rewards/core/theme/app_palette.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/common.dart';
import '../../../core/widgets/state_views.dart';
import 'package:go_router/go_router.dart';

import '../../../providers/repositories.dart';
import '../admin_providers.dart';

/// Contest claim reviews. Also gives quick access to manage contests.
class AdminContestClaimsTab extends ConsumerWidget {
  const AdminContestClaimsTab({super.key});

  Future<void> _resolve(
      BuildContext context, WidgetRef ref, String id, bool approve) async {
    try {
      await ref.read(adminRepositoryProvider).resolveContestClaim(id, approve);
      ref.invalidate(adminContestClaimsProvider('claim_pending'));
      ref.invalidate(adminAnalyticsProvider);
      if (context.mounted) {
        showSnack(context, approve ? 'Approved & rewarded' : 'Rejected');
      }
    } catch (e) {
      if (context.mounted) showSnack(context, '$e', error: true);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(adminContestClaimsProvider('claim_pending'));
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/admin/contests'),
        icon: const Icon(Icons.settings_rounded),
        label: const Text('Manage contests'),
      ),
      body: async.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(
            error: e,
            onRetry: () =>
                ref.invalidate(adminContestClaimsProvider('claim_pending'))),
        data: (list) {
          if (list.isEmpty) {
            return const EmptyView(
              icon: Icons.emoji_events_outlined,
              title: 'No contest claims',
              subtitle: 'Pending contest claims will appear here.',
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: list.length,
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (_, i) {
              final c = list[i];
              final progress = (c['progress'] as num?)?.toInt() ?? 0;
              final target = (c['target_value'] as num?)?.toInt() ?? 0;
              final reached = progress >= target;
              final ends = c['ends_at'] != null
                  ? DateTime.tryParse(c['ends_at'] as String)
                  : null;
              return SectionCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text('${c['contest_name'] ?? 'Contest'}',
                              style: const TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.w800)),
                        ),
                        BcpAmount((c['reward'] as num?)?.toInt() ?? 0,
                            showSign: true),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text('${c['user_name'] ?? '—'} · ${c['user_email'] ?? ''}',
                        style: TextStyle(color: context.cx.textSecondary)),
                    const SizedBox(height: 6),
                    Text('Progress: $progress / $target',
                        style: TextStyle(
                            color: reached
                                ? AppColors.success
                                : context.cx.textSecondary,
                            fontWeight: FontWeight.w600)),
                    if (ends != null)
                      Text('Deadline: ${Fmt.dateTime(ends)}',
                          style: TextStyle(
                              color: context.cx.textSecondary, fontSize: 12)),
                    if (!reached)
                      const Padding(
                        padding: EdgeInsets.only(top: 4),
                        child: Text(
                            'Server progress is below target — reject unless verified otherwise.',
                            style: TextStyle(
                                color: AppColors.danger, fontSize: 12)),
                      ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () =>
                                _resolve(context, ref, c['id'] as String, false),
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
      ),
    );
  }
}
