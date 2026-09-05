import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/common.dart';
import '../../../core/widgets/state_views.dart';
import '../../../providers/repositories.dart';
import '../admin_providers.dart';
import 'admin_setting_control.dart';

/// Admin → Ads — the single home for the whole ads system:
///   1. Global controls (master ON/OFF, test/production mode, reward economics)
///   2. Ad IDs / Placement IDs per network (AdMob / AppLovin MAX / Unity Ads)
///   3. Per-placement network selection (rewarded + banner)
///   4. Per-placement gating (rewarded required / banner shown)
///   5. Real, DB-backed ads analytics from the ad_events funnel
///
/// SECURITY: only dynamic Ad unit / placement IDs and network selection are
/// managed here. The AppLovin MAX SDK key and Unity Game ID are NEVER stored or
/// shown — they are build-time GitHub Actions secrets injected into the APK.
/// Reward verification stays server-side and network-agnostic (ad_events).
class AdminAdsTab extends ConsumerWidget {
  const AdminAdsTab({super.key});

  // Ad placements (stored key → display label).
  static const Map<String, String> _placements = {
    'daily': 'Daily Reward',
    'scratch': 'Scratch Card',
    'mining': 'Mining',
    'watch_ads': 'Watch Ads',
    'quiz': 'Quiz',
    'tasks': 'Tasks',
    'contest': 'Contest',
    'search': 'Search Card',
  };

  // Placements that expose a rewarded gate / a banner (matches the server).
  static const List<String> _rewardedPlacements = [
    'daily', 'scratch', 'watch_ads', 'quiz', 'tasks', 'contest', 'search',
  ];
  static const List<String> _bannerPlacements = [
    'daily', 'scratch', 'mining', 'watch_ads', 'quiz', 'tasks', 'search',
  ];

  static const List<Spec> _globalControls = [
    Spec('ads_system_enabled', 'Master ads switch', SettingKind.toggle,
        'OFF disables ALL ads (rewarded + banner) app-wide'),
    Spec('ads_test_mode', 'Test mode', SettingKind.toggle,
        'ON serves test ads; OFF uses the production Ad IDs below'),
    Spec('rewarded_ads_enabled', 'Rewarded ads', SettingKind.toggle,
        'Master switch for all rewarded ads'),
    Spec('banner_ads_enabled', 'Banner ads', SettingKind.toggle,
        'Master switch for all banner ads'),
    Spec('ads_reward', 'Watch-ad reward (BCP)', SettingKind.number),
    Spec('rewarded_daily_cap', 'Completed rewarded ads / day (all sections)',
        SettingKind.number),
    Spec('ads_daily_cap', 'Watch-Ads rewards per day', SettingKind.number),
    Spec('ads_min_gap_seconds', 'Min seconds between ads', SettingKind.number),
  ];

  // Ad unit / placement IDs per network. NOT SDK keys.
  static const List<Spec> _adIds = [
    Spec('admob_rewarded_id', 'AdMob · Rewarded ad unit ID', SettingKind.text),
    Spec('admob_banner_id', 'AdMob · Banner ad unit ID', SettingKind.text),
    Spec('applovin_rewarded_id', 'AppLovin MAX · Rewarded ad unit ID',
        SettingKind.text),
    Spec('applovin_banner_id', 'AppLovin MAX · Banner ad unit ID',
        SettingKind.text),
    Spec('unity_rewarded_id', 'Unity Ads · Rewarded placement ID',
        SettingKind.text),
    Spec('unity_banner_id', 'Unity Ads · Banner placement ID',
        SettingKind.text),
  ];

  Future<void> _save(
      BuildContext context, WidgetRef ref, String key, dynamic value) async {
    try {
      await ref.read(adminRepositoryProvider).setSetting(key, value);
      ref.invalidate(adminSettingsProvider);
      if (context.mounted) showSnack(context, 'Saved');
    } catch (e) {
      if (context.mounted) showSnack(context, '$e', error: true);
    }
  }

  List<Spec> get _networkSelection => [
        for (final e in _placements.entries)
          Spec('ad_network_${e.key}', '${e.value} · rewarded network',
              SettingKind.choice, null, kAdNetworks),
        for (final e in _placements.entries)
          Spec('banner_network_${e.key}', '${e.value} · banner network',
              SettingKind.choice, null, kAdNetworks),
      ];

  List<Spec> get _gating => [
        for (final p in _rewardedPlacements)
          Spec('ad_gate_$p', '${_placements[p]} · rewarded required',
              SettingKind.toggle),
        for (final p in _bannerPlacements)
          Spec('banner_$p', '${_placements[p]} · banner', SettingKind.toggle),
      ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(adminSettingsProvider);
    return async.when(
      loading: () => const LoadingView(),
      error: (e, _) => ErrorView(
          error: e, onRetry: () => ref.invalidate(adminSettingsProvider)),
      data: (settings) {
        final byKey = {for (final s in settings) s['key'] as String: s};

        Widget controls(String title, List<Spec> specs, {String? note}) {
          return CategoryCard(
            title: title,
            children: [
              if (note != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(note,
                      style:
                          const TextStyle(fontSize: 12, color: Colors.grey)),
                ),
              for (final sp in specs)
                if (byKey.containsKey(sp.key))
                  SettingControl(
                    spec: sp,
                    value: byKey[sp.key]!['value'],
                    onSave: (v) => _save(context, ref, sp.key, v),
                  ),
            ],
          );
        }

        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const _AdsAnalyticsCard(),
            controls('Global controls', _globalControls),
            controls(
              'Ad IDs / placements',
              _adIds,
              note: 'Dynamic Ad unit / placement IDs only. The AppLovin SDK key '
                  'and Unity Game ID are build-time secrets and are never stored '
                  'here. Leave blank (or keep Test mode ON) to serve test ads.',
            ),
            controls('Per-placement network', _networkSelection,
                note: 'Choose AdMob / AppLovin MAX / Unity Ads separately for '
                    'each placement. A network without its build-time key falls '
                    'back to AdMob test ads.'),
            controls('Per-placement gating', _gating),
            const SizedBox(height: 80),
          ],
        );
      },
    );
  }
}

/// Real ads funnel metrics from the ad_events table (admin_ads_analytics).
class _AdsAnalyticsCard extends ConsumerWidget {
  const _AdsAnalyticsCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(adminAdsAnalyticsProvider);
    return CategoryCard(
      title: 'Ads analytics',
      children: [
        async.when(
          loading: () => const Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (e, _) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                Expanded(child: Text('$e', style: const TextStyle(fontSize: 12))),
                TextButton(
                  onPressed: () =>
                      ref.invalidate(adminAdsAnalyticsProvider),
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
          data: (data) {
            final totals =
                (data['totals'] as Map?)?.cast<String, dynamic>() ?? const {};
            final byNet = ((data['by_network'] as List?) ?? const [])
                .map((e) => (e as Map).cast<String, dynamic>())
                .toList();
            int n(String k) => (totals[k] as num?)?.toInt() ?? 0;

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    _metric('Requests', n('requests')),
                    _metric('Impressions', n('impressions')),
                    _metric('Rewarded', n('rewarded')),
                    _metric('Verified credits', n('credited')),
                    _metric('BCP credited', n('credited_bcp')),
                  ],
                ),
                if (byNet.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  const Text('By network',
                      style: TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 6),
                  _NetworkTable(rows: byNet),
                ],
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _metric(String label, int value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$value',
              style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: AppColors.primary)),
          Text(label, style: const TextStyle(fontSize: 11)),
        ],
      ),
    );
  }
}

class _NetworkTable extends StatelessWidget {
  final List<Map<String, dynamic>> rows;
  const _NetworkTable({required this.rows});

  @override
  Widget build(BuildContext context) {
    int n(Map<String, dynamic> r, String k) => (r[k] as num?)?.toInt() ?? 0;
    const head = TextStyle(fontSize: 11, fontWeight: FontWeight.w800);
    const cell = TextStyle(fontSize: 12);
    return Table(
      columnWidths: const {
        0: FlexColumnWidth(2),
        1: FlexColumnWidth(1),
        2: FlexColumnWidth(1),
        3: FlexColumnWidth(1),
        4: FlexColumnWidth(1),
      },
      children: [
        const TableRow(children: [
          Padding(padding: EdgeInsets.all(4), child: Text('Network', style: head)),
          Padding(padding: EdgeInsets.all(4), child: Text('Req', style: head)),
          Padding(padding: EdgeInsets.all(4), child: Text('Imp', style: head)),
          Padding(padding: EdgeInsets.all(4), child: Text('Rew', style: head)),
          Padding(padding: EdgeInsets.all(4), child: Text('Cred', style: head)),
        ]),
        for (final r in rows)
          TableRow(children: [
            Padding(
                padding: const EdgeInsets.all(4),
                child: Text(
                    kAdNetworkLabels[r['network']] ?? '${r['network']}',
                    style: cell)),
            Padding(
                padding: const EdgeInsets.all(4),
                child: Text('${n(r, 'requests')}', style: cell)),
            Padding(
                padding: const EdgeInsets.all(4),
                child: Text('${n(r, 'impressions')}', style: cell)),
            Padding(
                padding: const EdgeInsets.all(4),
                child: Text('${n(r, 'rewarded')}', style: cell)),
            Padding(
                padding: const EdgeInsets.all(4),
                child: Text('${n(r, 'credited')}', style: cell)),
          ]),
      ],
    );
  }
}
