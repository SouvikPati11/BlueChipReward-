import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:bluechip_rewards/core/theme/app_colors.dart';
import 'package:bluechip_rewards/core/theme/app_palette.dart';
import '../../../core/widgets/common.dart';
import '../manage/manage_links.dart';
import '../manage/manage_milestones.dart';
import '../manage/manage_payment_methods.dart';
import '../manage/manage_quizzes.dart';
import '../manage/manage_referral.dart';
import '../manage/manage_tasks.dart';

/// Hub for content management: tasks, quizzes and payment methods.
class AdminContentTab extends ConsumerWidget {
  const AdminContentTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _tile(context, Icons.checklist_rounded, 'Tasks',
            'Create, edit and remove earning tasks', const ManageTasksScreen()),
        const SizedBox(height: 12),
        _tile(context, Icons.psychology_rounded, 'Quizzes',
            'Create quizzes and manage questions', const ManageQuizzesScreen()),
        const SizedBox(height: 12),
        _tile(context, Icons.account_balance_rounded, 'Payment methods',
            'Withdrawal methods and required fields',
            const ManagePaymentMethodsScreen()),
        const SizedBox(height: 12),
        _tile(context, Icons.account_tree_rounded, 'Referral levels',
            'Configure multi-level fixed / percentage rewards',
            const ManageReferralScreen()),
        const SizedBox(height: 12),
        _tile(context, Icons.emoji_events_rounded, 'Invite milestones',
            'Reward users for reaching referral counts',
            const ManageMilestonesScreen()),
        const SizedBox(height: 12),
        _tile(context, Icons.link_rounded, 'Links',
            'Support, social and page links shown in the app',
            const ManageLinksScreen()),
      ],
    );
  }

  Widget _tile(BuildContext context, IconData icon, String title, String sub,
      Widget screen) {
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () => Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => screen)),
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
