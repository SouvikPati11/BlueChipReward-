import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/state_views.dart';
import '../../providers/data_providers.dart';
import '../../providers/repositories.dart';
import 'package:bluechip_rewards/core/theme/app_palette.dart';

class NotificationsScreen extends ConsumerWidget {
  const NotificationsScreen({super.key});

  IconData _icon(String type) {
    switch (type) {
      case 'reward':
        return Icons.emoji_events_rounded;
      case 'withdrawal':
        return Icons.account_balance_wallet_rounded;
      case 'task':
        return Icons.task_alt_rounded;
      case 'daily':
        return Icons.redeem_rounded;
      case 'announcement':
        return Icons.campaign_rounded;
      default:
        return Icons.notifications_rounded;
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(notificationsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: SafeArea(
        top: false,
        child: async.when(
          loading: () => const LoadingView(),
          error: (e, _) => ErrorView(
              error: e, onRetry: () => ref.invalidate(notificationsProvider)),
          data: (list) {
            if (list.isEmpty) {
              return const EmptyView(
                icon: Icons.notifications_off_rounded,
                title: 'No notifications',
                subtitle: 'We\'ll let you know when something happens.',
              );
            }
            return ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: list.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final n = list[i];
                return ListTile(
                  onTap: () {
                    if (!n.read) {
                      ref
                          .read(userRepositoryProvider)
                          .markNotificationRead(n.id);
                      ref.invalidate(notificationsProvider);
                    }
                    // Deep-link: reminders and reward events carry a route.
                    final route = n.route;
                    if (route != null) context.push(route);
                  },
                  leading: CircleAvatar(
                    backgroundColor: AppColors.primary
                        .withValues(alpha: n.read ? .06 : .14),
                    child: Icon(_icon(n.type),
                        color: n.read
                            ? context.cx.textSecondary
                            : AppColors.primary),
                  ),
                  title: Text(n.title,
                      style: TextStyle(
                          fontWeight:
                              n.read ? FontWeight.w600 : FontWeight.w800)),
                  subtitle: n.body != null ? Text(n.body!) : null,
                  trailing: Text(Fmt.timeAgo(n.createdAt),
                      style: TextStyle(
                          fontSize: 11, color: context.cx.textSecondary)),
                );
              },
            );
          },
        ),
      ),
    );
  }
}
