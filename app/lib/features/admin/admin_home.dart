import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_colors.dart';
import '../../core/widgets/state_views.dart';
import '../../providers/auth_providers.dart';
import 'tabs/admin_dashboard_tab.dart';
import 'tabs/admin_settings_tab.dart';
import 'tabs/admin_tasks_tab.dart';
import 'tabs/admin_users_tab.dart';
import 'tabs/admin_withdrawals_tab.dart';

/// The admin panel is only revealed when the server confirms the admin role.
/// Every action inside also re-checks authorisation server-side, so this gate
/// is a convenience, not the security boundary.
class AdminHome extends ConsumerWidget {
  const AdminHome({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
        return DefaultTabController(
          length: 5,
          child: Scaffold(
            appBar: AppBar(
              title: const Text('Admin Panel'),
              bottom: const TabBar(
                isScrollable: true,
                labelColor: AppColors.primary,
                indicatorColor: AppColors.primary,
                tabs: [
                  Tab(text: 'Dashboard'),
                  Tab(text: 'Withdrawals'),
                  Tab(text: 'Tasks'),
                  Tab(text: 'Users'),
                  Tab(text: 'Config'),
                ],
              ),
            ),
            body: const TabBarView(
              children: [
                AdminDashboardTab(),
                AdminWithdrawalsTab(),
                AdminTasksTab(),
                AdminUsersTab(),
                AdminSettingsTab(),
              ],
            ),
          ),
        );
      },
    );
  }
}
