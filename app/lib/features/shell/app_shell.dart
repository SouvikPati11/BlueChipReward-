import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_colors.dart';
import '../earn/earn_hub_screen.dart';
import '../home/home_screen.dart';
import '../profile/profile_screen.dart';
import '../referral/referral_screen.dart';
import '../wallet/wallet_screen.dart';
import 'package:bluechip_rewards/core/theme/app_palette.dart';

/// Bottom-nav scaffold. The active tab is derived from the current route.
class AppShell extends StatelessWidget {
  final Widget child;
  const AppShell({super.key, required this.child});

  static const _tabs = ['/home', '/earn', '/wallet', '/referral', '/profile'];

  int _indexFor(String location) {
    final i = _tabs.indexWhere((t) => location.startsWith(t));
    return i < 0 ? 0 : i;
  }

  @override
  Widget build(BuildContext context) {
    final location = GoRouterState.of(context).matchedLocation;
    final index = _indexFor(location);

    return Scaffold(
      body: child,
      bottomNavigationBar: NavigationBarTheme(
        data: NavigationBarThemeData(
          backgroundColor: context.cx.surface,
          indicatorColor: AppColors.primary.withValues(alpha: .12),
          labelTextStyle: WidgetStateProperty.all(
            const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ),
        child: NavigationBar(
          height: 68,
          selectedIndex: index,
          onDestinationSelected: (i) => context.go(_tabs[i]),
          destinations: const [
            NavigationDestination(
                icon: Icon(Icons.home_outlined),
                selectedIcon: Icon(Icons.home_rounded),
                label: 'Home'),
            NavigationDestination(
                icon: Icon(Icons.bolt_outlined),
                selectedIcon: Icon(Icons.bolt_rounded),
                label: 'Earn'),
            NavigationDestination(
                icon: Icon(Icons.account_balance_wallet_outlined),
                selectedIcon: Icon(Icons.account_balance_wallet_rounded),
                label: 'Wallet'),
            NavigationDestination(
                icon: Icon(Icons.people_outline_rounded),
                selectedIcon: Icon(Icons.people_rounded),
                label: 'Refer'),
            NavigationDestination(
                icon: Icon(Icons.person_outline_rounded),
                selectedIcon: Icon(Icons.person_rounded),
                label: 'Profile'),
          ],
        ),
      ),
    );
  }
}

/// Renders the body for a given tab index.
class ShellPage extends StatelessWidget {
  final int index;
  const ShellPage(this.index, {super.key});

  @override
  Widget build(BuildContext context) {
    switch (index) {
      case 1:
        return const EarnHubScreen();
      case 2:
        return const WalletScreen();
      case 3:
        return const ReferralScreen();
      case 4:
        return const ProfileScreen();
      case 0:
      default:
        return const HomeScreen();
    }
  }
}
