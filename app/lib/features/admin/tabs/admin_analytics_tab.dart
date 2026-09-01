import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:bluechip_rewards/core/theme/app_colors.dart';
import 'package:bluechip_rewards/core/theme/app_palette.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/common.dart';
import '../../../core/widgets/state_views.dart';
import '../admin_providers.dart';

/// Analytics dashboard with server-side date filtering, ad funnel breakdown
/// and per-feature reward activity. Values show 0 (never blank).
class AdminAnalyticsTab extends ConsumerWidget {
  const AdminAnalyticsTab({super.key});

  static const _featureLabels = {
    'daily_reward': 'Daily reward',
    'mining': 'Mining',
    'scratch': 'Scratch',
    'ad': 'Watch ads',
    'quiz': 'Quiz',
    'task': 'Tasks',
    'referral': 'Referral',
    'invite_milestone': 'Invite milestone',
    'signup_bonus': 'Signup bonus',
    'admin_adjustment': 'Admin adjustment',
  };

  List<AnalyticsRange> _ranges() {
    final now = DateTime.now();
    final startToday = DateTime(now.year, now.month, now.day);
    return [
      AnalyticsRange('Today', startToday, null),
      AnalyticsRange('Yesterday', startToday.subtract(const Duration(days: 1)),
          startToday),
      AnalyticsRange('7 days', now.subtract(const Duration(days: 7)), null),
      AnalyticsRange('30 days', now.subtract(const Duration(days: 30)), null),
      AnalyticsRange('This month', DateTime(now.year, now.month, 1), null),
      allTimeRange(),
    ];
  }

  int _n(dynamic v) => (v as num?)?.toInt() ?? 0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final range = ref.watch(adminAnalyticsRangeProvider);
    final async = ref.watch(adminAnalyticsProvider);

    return Column(
      children: [
        SizedBox(
          height: 52,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            children: [
              for (final r in _ranges())
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(r.label),
                    selected: r.label == range.label,
                    onSelected: (_) => ref
                        .read(adminAnalyticsRangeProvider.notifier)
                        .state = r,
                  ),
                ),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ActionChip(
                  avatar: const Icon(Icons.date_range_rounded, size: 18),
                  label: const Text('Custom'),
                  onPressed: () async {
                    final picked = await showDateRangePicker(
                      context: context,
                      firstDate: DateTime(2024),
                      lastDate: DateTime.now().add(const Duration(days: 1)),
                    );
                    if (picked != null) {
                      ref.read(adminAnalyticsRangeProvider.notifier).state =
                          AnalyticsRange(
                              'Custom',
                              picked.start,
                              picked.end.add(const Duration(days: 1)));
                    }
                  },
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: async.when(
            loading: () => const LoadingView(),
            error: (e, _) => ErrorView(
                error: e, onRetry: () => ref.invalidate(adminAnalyticsProvider)),
            data: (d) {
              final ads = (d['ads'] as Map?)?.cast<String, dynamic>() ?? {};
              final features =
                  (d['features'] as Map?)?.cast<String, dynamic>() ?? {};
              return RefreshIndicator(
                onRefresh: () async {
                  ref.invalidate(adminAnalyticsProvider);
                  await ref.read(adminAnalyticsProvider.future);
                },
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Text('Range: ${range.label}',
                        style: TextStyle(color: context.cx.textSecondary)),
                    const SizedBox(height: 12),
                    _grid([
                      _Metric('Total users', '${_n(d['total_users'])}',
                          Icons.group_rounded),
                      _Metric('New users', '${_n(d['new_users'])}',
                          Icons.person_add_rounded),
                      _Metric('Active users', '${_n(d['active_users'])}',
                          Icons.bolt_rounded),
                      _Metric('Pending payouts',
                          '${_n(d['pending_withdrawals'])}',
                          Icons.hourglass_bottom_rounded),
                      _Metric('BCP earned', Fmt.points(_n(d['bcp_earned'])),
                          Icons.savings_rounded),
                      _Metric('BCP withdrawn',
                          Fmt.points(_n(d['bcp_withdrawn'])),
                          Icons.payments_rounded),
                    ]),
                    const SizedBox(height: 20),
                    const Text('Ad performance',
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 10),
                    SectionCard(
                      child: Column(
                        children: [
                          _row(context, 'Requests', _n(ads['requests'])),
                          const Divider(height: 18),
                          _row(context, 'Impressions', _n(ads['impressions'])),
                          const Divider(height: 18),
                          _row(context, 'Rewarded completions',
                              _n(ads['rewarded'])),
                          const Divider(height: 18),
                          _row(context, 'Reward credits', _n(ads['credits'])),
                          const Divider(height: 18),
                          _row(context, 'Watch-ads BCP paid',
                              _n(ads['credited_bcp'])),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    const Text('Reward activity by feature',
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 10),
                    SectionCard(
                      child: Column(
                        children: [
                          for (final entry in _featureLabels.entries) ...[
                            _featureRow(context, entry.value,
                                features[entry.key]),
                            if (entry.key != _featureLabels.keys.last)
                              const Divider(height: 18),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _grid(List<_Metric> metrics) {
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: 1.7,
      children: metrics,
    );
  }

  Widget _row(BuildContext context, String label, int value) {
    return Row(
      children: [
        Expanded(
            child: Text(label,
                style: TextStyle(color: context.cx.textSecondary))),
        Text('$value',
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
      ],
    );
  }

  Widget _featureRow(BuildContext context, String label, dynamic data) {
    final m = (data as Map?)?.cast<String, dynamic>();
    final count = (m?['count'] as num?)?.toInt() ?? 0;
    final bcp = (m?['bcp'] as num?)?.toInt() ?? 0;
    return Row(
      children: [
        Expanded(
            child: Text(label,
                style: const TextStyle(fontWeight: FontWeight.w600))),
        Text('$count × ',
            style: TextStyle(color: context.cx.textSecondary)),
        Text(Fmt.points(bcp),
            style: const TextStyle(
                fontWeight: FontWeight.w800, color: AppColors.gold)),
        const SizedBox(width: 4),
        const Text('BCP', style: TextStyle(fontSize: 12)),
      ],
    );
  }
}

class _Metric extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  const _Metric(this.label, this.value, this.icon);

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: AppColors.primary, size: 20),
          const SizedBox(height: 6),
          Text(value,
              style:
                  const TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
          Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: context.cx.textSecondary, fontSize: 12)),
        ],
      ),
    );
  }
}
