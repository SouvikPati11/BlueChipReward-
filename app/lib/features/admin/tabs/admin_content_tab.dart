import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:bluechip_rewards/core/theme/app_colors.dart';
import 'package:bluechip_rewards/core/theme/app_palette.dart';
import '../../../core/widgets/common.dart';

/// Hub for content management. Each tile navigates to a real `/admin/...`
/// GoRouter sub-route so Android Back is deterministic (screen → Content →
/// Dashboard) and never jumps to the User panel.
class AdminContentTab extends ConsumerWidget {
  const AdminContentTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _tile(context, Icons.checklist_rounded, 'Tasks',
            'Create, edit and remove earning tasks', '/admin/tasks'),
        const SizedBox(height: 12),
        _tile(context, Icons.psychology_rounded, 'Quizzes',
            'Create quizzes and manage questions', '/admin/quizzes'),
        const SizedBox(height: 12),
        _tile(context, Icons.account_balance_rounded, 'Payment methods',
            'Withdrawal methods and required fields', '/admin/payment-methods'),
        const SizedBox(height: 12),
        _tile(context, Icons.account_tree_rounded, 'Referral levels',
            'Configure multi-level fixed / percentage rewards',
            '/admin/referral-levels'),
        const SizedBox(height: 12),
        _tile(context, Icons.style_rounded, 'Scratch Card rules',
            'Reward ranges, ads, delays & cooldown per band',
            '/admin/scratch-rules'),
        const SizedBox(height: 12),
        _tile(context, Icons.smart_display_rounded, 'Watch Ads rules',
            'Reward ranges, cooldown, wait & daily limit per band',
            '/admin/watch-ad-rules'),
        const SizedBox(height: 12),
        _tile(context, Icons.emoji_events_rounded, 'Invite milestones',
            'Reward users for reaching referral counts', '/admin/milestones'),
        const SizedBox(height: 12),
        _tile(context, Icons.notifications_active_rounded,
            'Custom notifications',
            'Compose and send push/in-app notifications; view history',
            '/admin/notifications'),
        const SizedBox(height: 12),
        _tile(context, Icons.link_rounded, 'Links',
            'Support, social and page links shown in the app', '/admin/links'),
      ],
    );
  }

  Widget _tile(BuildContext context, IconData icon, String title, String sub,
      String route) {
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () => context.push(route),
      child: SectionCard(
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: .12),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(icon, color: AppColors.primary),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w800)),
                  Text(sub, style: TextStyle(color: context.cx.textSecondary)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded),
          ],
        ),
      ),
    );
  }
}
