import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../features/admin/admin_home.dart';
import '../../features/admin/manage/manage_contests.dart';
import '../../features/admin/manage/manage_links.dart';
import '../../features/admin/manage/manage_milestones.dart';
import '../../features/admin/manage/manage_notifications.dart';
import '../../features/admin/manage/manage_payment_methods.dart';
import '../../features/admin/manage/manage_quizzes.dart';
import '../../features/admin/manage/manage_referral.dart';
import '../../features/admin/manage/manage_scratch_rules.dart';
import '../../features/admin/manage/manage_tasks.dart';
import '../../features/admin/manage/manage_watch_ad_rules.dart';
import '../../features/auth/forgot_password_screen.dart';
import '../../features/auth/login_screen.dart';
import '../../features/auth/register_screen.dart';
import '../../features/earn/ads/watch_ads_screen.dart';
import '../../features/earn/daily/daily_reward_screen.dart';
import '../../features/earn/mining/mining_screen.dart';
import '../../features/contest/contest_screen.dart';
import '../../features/earn/invite/invite_milestones_screen.dart';
import '../../features/earn/quiz/quiz_screen.dart';
import '../../features/earn/scratch/scratch_screen.dart';
import '../../features/earn/tasks/tasks_screen.dart';
import '../../features/notifications/notifications_screen.dart';
import '../../features/profile/settings_screen.dart';
import '../../features/shell/app_shell.dart';
import '../../features/splash/splash_screen.dart';
import '../../features/withdrawal/withdraw_screen.dart';
import '../../features/withdrawal/withdrawals_history_screen.dart';
import '../supabase/supabase_client.dart';

/// The live [GoRouter] instance, exposed so out-of-widget code (a push
/// notification tap handled in a background isolate hand-off, for example) can
/// navigate without a BuildContext. Set when the router provider is built.
GoRouter? appRouter;

final routerProvider = Provider<GoRouter>((ref) {
  final refresh = _AuthRefresh(Db.auth.onAuthStateChange);
  ref.onDispose(refresh.dispose);

  final router = GoRouter(
    initialLocation: '/splash',
    refreshListenable: refresh,
    redirect: (context, state) {
      final signedIn = Db.auth.currentSession != null;
      final loc = state.matchedLocation;
      final onSplash = loc == '/splash';
      final onAuth = loc == '/login' ||
          loc == '/register' ||
          loc == '/forgot';

      if (onSplash) return null; // splash decides
      if (!signedIn && !onAuth) return '/login';
      if (signedIn && onAuth) return '/home';
      return null;
    },
    routes: [
      GoRoute(path: '/splash', builder: (_, __) => const SplashScreen()),
      GoRoute(path: '/login', builder: (_, __) => const LoginScreen()),
      GoRoute(path: '/register', builder: (_, __) => const RegisterScreen()),
      GoRoute(
          path: '/forgot', builder: (_, __) => const ForgotPasswordScreen()),

      // Main shell with bottom navigation
      ShellRoute(
        builder: (_, __, child) => AppShell(child: child),
        routes: [
          GoRoute(path: '/home', builder: (_, __) => const ShellPage(0)),
          GoRoute(path: '/earn', builder: (_, __) => const ShellPage(1)),
          GoRoute(path: '/wallet', builder: (_, __) => const ShellPage(2)),
          GoRoute(path: '/referral', builder: (_, __) => const ShellPage(3)),
          GoRoute(path: '/profile', builder: (_, __) => const ShellPage(4)),
        ],
      ),

      // Earn detail screens
      GoRoute(path: '/earn/daily', builder: (_, __) => const DailyRewardScreen()),
      GoRoute(path: '/earn/mining', builder: (_, __) => const MiningScreen()),
      GoRoute(path: '/earn/scratch', builder: (_, __) => const ScratchScreen()),
      GoRoute(path: '/earn/ads', builder: (_, __) => const WatchAdsScreen()),
      GoRoute(path: '/earn/quiz', builder: (_, __) => const QuizScreen()),
      GoRoute(path: '/earn/tasks', builder: (_, __) => const TasksScreen()),
      GoRoute(
          path: '/refer/milestones',
          builder: (_, __) => const InviteMilestonesScreen()),
      GoRoute(path: '/contests', builder: (_, __) => const ContestScreen()),

      // Wallet / withdrawal
      GoRoute(path: '/withdraw', builder: (_, __) => const WithdrawScreen()),
      GoRoute(
          path: '/withdrawals',
          builder: (_, __) => const WithdrawalsHistoryScreen()),

      // Misc
      GoRoute(
          path: '/notifications',
          builder: (_, __) => const NotificationsScreen()),
      GoRoute(path: '/settings', builder: (_, __) => const SettingsScreen()),
      // Admin panel. Nested manage screens are real GoRouter sub-routes so the
      // back stack is deterministic (Editor → Manage → Dashboard) and survives
      // a router refresh — Android Back never jumps to the User panel.
      GoRoute(
        path: '/admin',
        builder: (_, __) => const AdminHome(),
        routes: [
          GoRoute(
              path: 'tasks',
              builder: (_, __) => const ManageTasksScreen()),
          GoRoute(
              path: 'quizzes',
              builder: (_, __) => const ManageQuizzesScreen()),
          GoRoute(
              path: 'payment-methods',
              builder: (_, __) => const ManagePaymentMethodsScreen()),
          GoRoute(
              path: 'referral-levels',
              builder: (_, __) => const ManageReferralScreen()),
          GoRoute(
              path: 'milestones',
              builder: (_, __) => const ManageMilestonesScreen()),
          GoRoute(
              path: 'notifications',
              builder: (_, __) => const ManageNotificationsScreen()),
          GoRoute(
              path: 'scratch-rules',
              builder: (_, __) => const ManageScratchRulesScreen()),
          GoRoute(
              path: 'watch-ad-rules',
              builder: (_, __) => const ManageWatchAdRulesScreen()),
          GoRoute(
              path: 'links', builder: (_, __) => const ManageLinksScreen()),
          GoRoute(
              path: 'contests',
              builder: (_, __) => const ManageContestsScreen()),
        ],
      ),
    ],
  );
  appRouter = router;
  return router;
});

class _AuthRefresh extends ChangeNotifier {
  late final StreamSubscription<AuthState> _sub;
  _AuthRefresh(Stream<AuthState> stream) {
    // Only re-evaluate routing on real auth transitions. In particular we must
    // NOT rebuild on `tokenRefreshed`/`userUpdated`: those fire periodically and
    // on resume, and a GoRouter rebuild would drop imperatively-pushed pages
    // (e.g. an open Admin screen), bouncing the user back to Home. This was the
    // cause of the "Admin back jumps to User Home" bug.
    _sub = stream.listen((state) {
      switch (state.event) {
        case AuthChangeEvent.signedIn:
        case AuthChangeEvent.signedOut:
        case AuthChangeEvent.initialSession:
        case AuthChangeEvent.passwordRecovery:
          notifyListeners();
          break;
        default:
          break; // tokenRefreshed, userUpdated, mfa events → no routing change
      }
    });
  }
  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }
}
