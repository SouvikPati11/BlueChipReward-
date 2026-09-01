import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:bluechip_rewards/core/theme/app_colors.dart';
import 'package:bluechip_rewards/core/theme/app_palette.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/state_views.dart';
import '../admin_providers.dart';

class AdminAuditTab extends ConsumerWidget {
  const AdminAuditTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(adminAuditProvider);
    return async.when(
      loading: () => const LoadingView(),
      error: (e, _) =>
          ErrorView(error: e, onRetry: () => ref.invalidate(adminAuditProvider)),
      data: (logs) {
        if (logs.isEmpty) {
          return const EmptyView(
              icon: Icons.receipt_long_rounded, title: 'No audit entries yet');
        }
        return RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(adminAuditProvider);
            await ref.read(adminAuditProvider.future);
          },
          child: ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: logs.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final l = logs[i];
              return ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const CircleAvatar(
                  backgroundColor: Color(0x142563EB),
                  child: Icon(Icons.history_rounded, color: AppColors.primary),
                ),
                title: Text(l['action'] ?? '',
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text(
                    '${l['entity'] ?? ''} ${l['entity_id'] ?? ''}'.trim(),
                    style: TextStyle(color: context.cx.textSecondary)),
                trailing: Text(
                    Fmt.timeAgo(DateTime.parse(l['created_at'] as String)),
                    style: const TextStyle(fontSize: 11)),
              );
            },
          ),
        );
      },
    );
  }
}
