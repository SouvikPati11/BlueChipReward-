import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/common.dart';
import '../../../core/widgets/state_views.dart';
import '../../../providers/repositories.dart';
import '../admin_providers.dart';

class AdminUsersTab extends ConsumerStatefulWidget {
  const AdminUsersTab({super.key});

  @override
  ConsumerState<AdminUsersTab> createState() => _AdminUsersTabState();
}

class _AdminUsersTabState extends ConsumerState<AdminUsersTab> {
  String _search = '';

  Future<void> _setStatus(String userId, String status) async {
    try {
      await ref.read(adminRepositoryProvider).setUserStatus(userId, status);
      ref.invalidate(adminUsersProvider(_search));
      if (mounted) showSnack(context, 'User $status');
    } catch (e) {
      if (mounted) showSnack(context, '$e', error: true);
    }
  }

  Future<void> _adjust(String userId) async {
    final ctrl = TextEditingController();
    final reason = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Adjust balance'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: ctrl,
              keyboardType:
                  const TextInputType.numberWithOptions(signed: true),
              decoration: const InputDecoration(
                  labelText: 'Amount (+/-)', hintText: 'e.g. 500 or -200'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: reason,
              decoration: const InputDecoration(labelText: 'Reason'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Apply')),
        ],
      ),
    );
    if (ok != true) return;
    final amount = int.tryParse(ctrl.text.trim());
    if (amount == null || amount == 0) return;
    try {
      await ref
          .read(adminRepositoryProvider)
          .adjustBalance(userId, amount, reason.text.trim());
      ref.invalidate(adminUsersProvider(_search));
      if (mounted) showSnack(context, 'Balance adjusted');
    } catch (e) {
      if (mounted) showSnack(context, '$e', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(adminUsersProvider(_search));
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: TextField(
            decoration: const InputDecoration(
              hintText: 'Search by email',
              prefixIcon: Icon(Icons.search_rounded),
            ),
            onSubmitted: (v) => setState(() => _search = v),
          ),
        ),
        Expanded(
          child: async.when(
            loading: () => const LoadingView(),
            error: (e, _) => ErrorView(
                error: e,
                onRetry: () => ref.invalidate(adminUsersProvider(_search))),
            data: (users) {
              if (users.isEmpty) {
                return const EmptyView(
                    icon: Icons.person_off_rounded, title: 'No users found');
              }
              return ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                itemCount: users.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (_, i) {
                  final u = users[i];
                  final balance =
                      (u['wallets'] as Map?)?['balance'] ?? 0;
                  final status = u['status'] as String? ?? 'active';
                  return SectionCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(u['full_name'] ?? u['email'] ?? 'User',
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w800)),
                                  Text(u['email'] ?? '',
                                      style: TextStyle(
                                          color: AppColors.textSecondary,
                                          fontSize: 12)),
                                ],
                              ),
                            ),
                            Pill(status.toUpperCase(),
                                color: status == 'active'
                                    ? AppColors.success
                                    : AppColors.danger),
                          ],
                        ),
                        const SizedBox(height: 8),
                        BcpAmount(balance is num ? balance.toInt() : 0),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          children: [
                            OutlinedButton(
                              onPressed: () =>
                                  _adjust(u['id'] as String),
                              child: const Text('Adjust'),
                            ),
                            if (status == 'active')
                              OutlinedButton(
                                onPressed: () => _setStatus(
                                    u['id'] as String, 'suspended'),
                                style: OutlinedButton.styleFrom(
                                    foregroundColor: AppColors.warning,
                                    side: const BorderSide(
                                        color: AppColors.warning)),
                                child: const Text('Suspend'),
                              )
                            else
                              OutlinedButton(
                                onPressed: () => _setStatus(
                                    u['id'] as String, 'active'),
                                style: OutlinedButton.styleFrom(
                                    foregroundColor: AppColors.success,
                                    side: const BorderSide(
                                        color: AppColors.success)),
                                child: const Text('Activate'),
                              ),
                            OutlinedButton(
                              onPressed: () =>
                                  _setStatus(u['id'] as String, 'banned'),
                              style: OutlinedButton.styleFrom(
                                  foregroundColor: AppColors.danger,
                                  side: const BorderSide(
                                      color: AppColors.danger)),
                              child: const Text('Ban'),
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
        ),
      ],
    );
  }
}
