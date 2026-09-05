import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_colors.dart';
import '../../core/widgets/state_views.dart';
import '../../providers/auth_providers.dart';
import 'tabs/admin_ads_tab.dart';
import 'tabs/admin_analytics_tab.dart';
import 'tabs/admin_audit_tab.dart';
import 'tabs/admin_content_tab.dart';
import 'tabs/admin_contest_claims_tab.dart';
import 'tabs/admin_referral_reviews_tab.dart';
import 'tabs/admin_settings_tab.dart';
import 'tabs/admin_tasks_tab.dart';
import 'tabs/admin_users_tab.dart';
import 'tabs/admin_withdrawals_tab.dart';
import 'package:bluechip_rewards/core/theme/app_palette.dart';

class _Section {
  final String title;
  final IconData icon;
  final Widget body;
  const _Section(this.title, this.icon, this.body);
}

/// The admin panel is only revealed when the server confirms the admin role.
/// Every action inside also re-checks authorisation server-side, so this gate
/// is a convenience, not the security boundary.
///
/// Mobile-first navigation: a drawer of sections (no cramped horizontal tabs).
class AdminHome extends ConsumerStatefulWidget {
  const AdminHome({super.key});

  @override
  ConsumerState<AdminHome> createState() => _AdminHomeState();
}

class _AdminHomeState extends ConsumerState<AdminHome> {
  int _index = 0;

  static const _sections = <_Section>[
    _Section('Analytics', Icons.insights_rounded, AdminAnalyticsTab()),
    _Section('Withdrawals', Icons.payments_rounded, AdminWithdrawalsTab()),
    _Section('Task reviews', Icons.fact_check_rounded, AdminTasksTab()),
    _Section('Referral reviews', Icons.report_gmailerrorred_rounded,
        AdminReferralReviewsTab()),
    _Section('Contests', Icons.emoji_events_rounded, AdminContestClaimsTab()),
    _Section('Users', Icons.group_rounded, AdminUsersTab()),
    _Section('Content', Icons.dashboard_customize_rounded, AdminContentTab()),
    _Section('Ads', Icons.ondemand_video_rounded, AdminAdsTab()),
    _Section('Config', Icons.tune_rounded, AdminSettingsTab()),
    _Section('Audit log', Icons.receipt_long_rounded, AdminAuditTab()),
  ];

  @override
  Widget build(BuildContext context) {
    final isAdminAsync = ref.watch(isAdminProvider);

    return isAdminAsync.when(
      loading: () =>
          const Scaffold(body: LoadingView(label: 'Checking access…')),
      error: (e, _) => Scaffold(body: ErrorView(error: e)),
      data: (isAdmin) {
        if (!isAdmin) {
          return Scaffold(
            appBar: AppBar(title: const Text('Admin')),
            body: EmptyView(
              icon: Icons.lock_rounded,
              title: 'Access denied',
              subtitle: 'You do not have admin permissions.',
              action: ElevatedButton(
                onPressed: () => context.go('/home'),
                child: const Text('Back to home'),
              ),
            ),
          );
        }
        final section = _sections[_index];
        return Scaffold(
          appBar: AppBar(title: Text('Admin · ${section.title}')),
          drawer: Drawer(
            child: SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
                    child: Row(
                      children: [
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: AppColors.primary.withValues(alpha: .12),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(Icons.admin_panel_settings_rounded,
                              color: AppColors.primary),
                        ),
                        const SizedBox(width: 12),
                        const Text('Admin Panel',
                            style: TextStyle(
                                fontSize: 18, fontWeight: FontWeight.w800)),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      children: [
                        for (var i = 0; i < _sections.length; i++)
                          ListTile(
                            leading: Icon(_sections[i].icon,
                                color: i == _index
                                    ? AppColors.primary
                                    : context.cx.textSecondary),
                            title: Text(_sections[i].title,
                                style: TextStyle(
                                    fontWeight: i == _index
                                        ? FontWeight.w800
                                        : FontWeight.w500,
                                    color: i == _index
                                        ? AppColors.primary
                                        : null)),
                            selected: i == _index,
                            selectedTileColor:
                                AppColors.primary.withValues(alpha: .08),
                            onTap: () {
                              setState(() => _index = i);
                              Navigator.pop(context);
                            },
                          ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.home_rounded),
                    title: const Text('Back to app'),
                    onTap: () => context.go('/home'),
                  ),
                ],
              ),
            ),
          ),
          body: section.body,
        );
      },
    );
  }
}
