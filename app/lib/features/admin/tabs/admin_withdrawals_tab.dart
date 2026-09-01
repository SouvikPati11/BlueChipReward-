import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/common.dart';
import '../../../core/widgets/state_views.dart';
import '../../../providers/repositories.dart';
import '../admin_providers.dart';
import 'package:bluechip_rewards/core/theme/app_palette.dart';

/// Withdrawal review with full requester + payment detail (server-joined).
class AdminWithdrawalsTab extends ConsumerStatefulWidget {
  const AdminWithdrawalsTab({super.key});

  @override
  ConsumerState<AdminWithdrawalsTab> createState() =>
      _AdminWithdrawalsTabState();
}

class _AdminWithdrawalsTabState extends ConsumerState<AdminWithdrawalsTab> {
  String _status = 'pending';

  Future<void> _process(String id, String status) async {
    String? notes;
    if (status == 'rejected') {
      notes = await _askNotes();
      if (notes == null) return;
    }
    try {
      await ref
          .read(adminRepositoryProvider)
          .processWithdrawal(id, status, notes: notes);
      ref.invalidate(adminWithdrawalsDetailedProvider(_status));
      ref.invalidate(adminAnalyticsProvider);
      if (mounted) showSnack(context, 'Marked $status');
    } catch (e) {
      if (mounted) showSnack(context, '$e', error: true);
    }
  }

  Future<String?> _askNotes() {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Reason for rejection'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(hintText: 'Notes for the user'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.pop(context, ctrl.text.trim()),
              child: const Text('Reject')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(adminWithdrawalsDetailedProvider(_status));
    return Column(
      children: [
        SizedBox(
          height: 52,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            children: [
              for (final s in const ['pending', 'approved', 'paid', 'rejected', 'all'])
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(s[0].toUpperCase() + s.substring(1)),
                    selected: _status == s,
                    onSelected: (_) => setState(() => _status = s),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: async.when(
            loading: () => const LoadingView(),
            error: (e, _) => ErrorView(
                error: e,
                onRetry: () => ref
                    .invalidate(adminWithdrawalsDetailedProvider(_status))),
            data: (list) {
              if (list.isEmpty) {
                return const EmptyView(
                  icon: Icons.check_circle_rounded,
                  title: 'Nothing here',
                  subtitle: 'No withdrawals in this state.',
                );
              }
              return RefreshIndicator(
                onRefresh: () async {
                  ref.invalidate(adminWithdrawalsDetailedProvider(_status));
                  await ref
                      .read(adminWithdrawalsDetailedProvider(_status).future);
                },
                child: ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: list.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 12),
                  itemBuilder: (_, i) => _WithdrawalCard(
                    w: list[i],
                    onProcess: _process,
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _WithdrawalCard extends StatelessWidget {
  final Map<String, dynamic> w;
  final Future<void> Function(String id, String status) onProcess;
  const _WithdrawalCard({required this.w, required this.onProcess});

  Color _statusColor(String s) {
    switch (s) {
      case 'paid':
        return AppColors.success;
      case 'approved':
        return AppColors.info;
      case 'rejected':
        return AppColors.danger;
      default:
        return AppColors.warning;
    }
  }

  @override
  Widget build(BuildContext context) {
    final id = w['id'] as String;
    final status = (w['status'] as String?) ?? 'pending';
    final amount = (w['amount'] as num?)?.toInt() ?? 0;
    final details = (w['details'] as Map?)?.cast<String, dynamic>() ?? {};
    final createdAt = w['created_at'] != null
        ? DateTime.tryParse(w['created_at'] as String)
        : null;
    final processedAt = w['processed_at'] != null
        ? DateTime.tryParse(w['processed_at'] as String)
        : null;

    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              BcpAmount(amount, size: 18),
              const Spacer(),
              Pill(status.toUpperCase(), color: _statusColor(status)),
            ],
          ),
          const SizedBox(height: 10),
          _kv(context, 'User', '${w['user_name'] ?? '—'}'),
          _kv(context, 'Email', '${w['user_email'] ?? '—'}'),
          _kv(context, 'User ID', '${w['user_id'] ?? '—'}'),
          _kv(context, 'Ref code', '${w['referral_code'] ?? '—'}'),
          _kv(context, 'Balance', '${(w['balance'] as num?)?.toInt() ?? 0} BCP'),
          _kv(context, 'Method', '${w['method_name'] ?? w['method_key'] ?? '—'}'),
          if (details.isNotEmpty)
            for (final e in details.entries)
              _kv(context, _pretty(e.key), '${e.value}'),
          if (createdAt != null)
            _kv(context, 'Requested', Fmt.dateTime(createdAt)),
          if (processedAt != null)
            _kv(context, 'Processed', Fmt.dateTime(processedAt)),
          if ((w['admin_notes'] as String?)?.isNotEmpty ?? false)
            _kv(context, 'Notes', '${w['admin_notes']}'),
          if (status == 'pending' || status == 'approved') ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                if (status == 'pending')
                  OutlinedButton(
                    onPressed: () => onProcess(id, 'approved'),
                    child: const Text('Approve'),
                  ),
                ElevatedButton(
                  onPressed: () => onProcess(id, 'paid'),
                  style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.success,
                      minimumSize: const Size(90, 42)),
                  child: const Text('Mark paid'),
                ),
                OutlinedButton(
                  onPressed: () => onProcess(id, 'rejected'),
                  style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.danger,
                      side: const BorderSide(color: AppColors.danger),
                      minimumSize: const Size(90, 42)),
                  child: const Text('Reject'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  String _pretty(String k) =>
      k.replaceAll('_', ' ').replaceRange(0, 1, k[0].toUpperCase());

  Widget _kv(BuildContext context, String k, String v) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
              width: 92,
              child: Text(k,
                  style: TextStyle(color: context.cx.textSecondary))),
          Expanded(
              child: Text(v,
                  style: const TextStyle(fontWeight: FontWeight.w600))),
        ],
      ),
    );
  }
}
