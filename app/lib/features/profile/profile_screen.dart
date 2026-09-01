import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_colors.dart';
import '../../core/widgets/common.dart';
import '../../providers/auth_providers.dart';
import '../../providers/data_providers.dart';
import '../../providers/repositories.dart';
import 'package:bluechip_rewards/core/theme/app_palette.dart';

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profileAsync = ref.watch(profileProvider);
    final walletAsync = ref.watch(walletProvider);
    final isAdminAsync = ref.watch(isAdminProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            SectionCard(
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 32,
                    backgroundColor: AppColors.primary.withValues(alpha: .12),
                    backgroundImage: profileAsync.valueOrNull?.avatarUrl != null
                        ? NetworkImage(profileAsync.value!.avatarUrl!)
                        : null,
                    child: profileAsync.valueOrNull?.avatarUrl == null
                        ? Text(profileAsync.valueOrNull?.initials ?? 'U',
                            style: const TextStyle(
                                fontSize: 24,
                                color: AppColors.primary,
                                fontWeight: FontWeight.w800))
                        : null,
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(profileAsync.valueOrNull?.displayName ?? '—',
                            style: const TextStyle(
                                fontSize: 18, fontWeight: FontWeight.w800)),
                        Text(profileAsync.valueOrNull?.email ?? '',
                            style:
                                TextStyle(color: context.cx.textSecondary)),
                        const SizedBox(height: 6),
                        if (walletAsync.valueOrNull != null)
                          BcpAmount(walletAsync.value!.balance, size: 14),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => context.push('/settings'),
                    icon: const Icon(Icons.edit_rounded),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            _tile(context, Icons.account_balance_wallet_rounded, 'Wallet',
                () => context.go('/wallet')),
            _tile(context, Icons.receipt_long_rounded, 'Withdrawal history',
                () => context.push('/withdrawals')),
            _tile(context, Icons.people_rounded, 'Refer & earn',
                () => context.go('/referral')),
            _tile(context, Icons.notifications_rounded, 'Notifications',
                () => context.push('/notifications')),
            _tile(context, Icons.settings_rounded, 'Settings',
                () => context.push('/settings')),
            isAdminAsync.maybeWhen(
              data: (isAdmin) => isAdmin
                  ? _tile(context, Icons.admin_panel_settings_rounded,
                      'Admin panel', () => context.push('/admin'),
                      highlight: true)
                  : const SizedBox.shrink(),
              orElse: () => const SizedBox.shrink(),
            ),
            const SizedBox(height: 20),
            OutlinedButton.icon(
              onPressed: () async {
                await ref.read(authRepositoryProvider).signOut();
                if (context.mounted) context.go('/login');
              },
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.danger,
                side: const BorderSide(color: AppColors.danger),
              ),
              icon: const Icon(Icons.logout_rounded),
              label: const Text('Log out'),
            ),
            const SizedBox(height: 16),
            Center(
              child: Text('${DateTime.now().year} • BlueChip Rewards v1.0.2',
                  style: TextStyle(
                      color: context.cx.textSecondary, fontSize: 12)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tile(BuildContext context, IconData icon, String title,
      VoidCallback onTap,
      {bool highlight = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: highlight
            ? AppColors.primary.withValues(alpha: .08)
            : context.cx.surface,
        borderRadius: BorderRadius.circular(16),
        child: ListTile(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(
                color: highlight ? AppColors.primary : context.cx.border),
          ),
          leading: Icon(icon,
              color: highlight ? AppColors.primary : context.cx.textPrimary),
          title: Text(title,
              style: const TextStyle(fontWeight: FontWeight.w700)),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: onTap,
        ),
      ),
    );
  }
}
