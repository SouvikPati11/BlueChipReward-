import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/ad_gate.dart';
import '../../../core/widgets/banner_ad_bar.dart';
import '../../../core/widgets/common.dart';
import '../../../core/widgets/countdown.dart';
import '../../../core/widgets/state_views.dart';
import '../../../providers/data_providers.dart';
import '../../../providers/repositories.dart';
import 'package:bluechip_rewards/core/theme/app_palette.dart';

class WatchAdsScreen extends ConsumerStatefulWidget {
  const WatchAdsScreen({super.key});

  @override
  ConsumerState<WatchAdsScreen> createState() => _WatchAdsScreenState();
}

class _WatchAdsScreenState extends ConsumerState<WatchAdsScreen> {
  bool _busy = false;
  bool _loading = true;
  String? _error;
  Map<String, dynamic> _status = const {};

  @override
  void initState() {
    super.initState();
    ref.read(rewardedAdServiceProvider).preload();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final s = await ref.read(earnRepositoryProvider).watchAdsStatus();
      if (mounted) setState(() => _status = s);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  int get _min => (_status['min_reward'] as num?)?.toInt() ?? 0;
  int get _max => (_status['max_reward'] as num?)?.toInt() ?? 0;
  int get _remainingToday => (_status['remaining_today'] as num?)?.toInt() ?? 0;
  bool get _available => _status['available'] == true;
  bool get _cycleComplete => _status['cycle_complete'] == true;

  DateTime? get _nextAt {
    final s = _status['next_available_at'];
    if (s is String && s.isNotEmpty) return DateTime.tryParse(s);
    return null;
  }

  DateTime? get _nextCycleAt {
    final s = _status['next_cycle_at'];
    if (s is String && s.isNotEmpty) return DateTime.tryParse(s);
    return null;
  }

  Future<void> _watch() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final nonce = await runRewardedGate(ref, 'watch_ads');
      if (nonce == null) {
        if (mounted) {
          showSnack(context, 'Watch Ads is currently unavailable.',
              error: true);
        }
        return;
      }
      final res = await ref.read(earnRepositoryProvider).rewardAd(nonce);
      ref.invalidate(walletProvider);
      ref.invalidate(transactionsProvider);
      if (mounted) {
        await showRewardDialog(context,
            amount: (res['amount'] as num).toInt(), title: 'Ad reward!');
      }
    } catch (e) {
      if (mounted) showSnack(context, _friendly('$e'), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
      await _load(); // refresh cooldown / remaining from the server
    }
  }

  String _friendly(String e) {
    if (e.contains('AD_TOO_SOON')) return 'Please wait for the cooldown to finish.';
    if (e.contains('AD_DAILY_LIMIT')) return 'You have reached today\'s ad limit.';
    return e;
  }

  @override
  Widget build(BuildContext context) {
    final rewardLabel = _max <= 0
        ? 'Watch & Earn'
        : (_min == _max ? 'Earn up to $_max BCP' : 'Earn $_min–$_max BCP per ad');

    final cycleComplete = _cycleComplete && _nextCycleAt != null;
    final onCooldown = !_available && !cycleComplete && _nextAt != null;
    final limitReached = _remainingToday <= 0 && !_available;

    return Scaffold(
      appBar: AppBar(title: const Text('Watch Ads')),
      bottomNavigationBar: const BannerAdBar(placement: 'watch_ads'),
      body: SafeArea(
        top: false,
        child: _loading
            ? const LoadingView()
            : _error != null
                ? ErrorView(error: _error!, onRetry: _load)
                : RefreshIndicator(
                    onRefresh: _load,
                    child: ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        SectionCard(
                          gradient: const LinearGradient(
                            colors: [AppColors.success, Color(0xFF34D399)],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            children: [
                              Container(
                                width: 90,
                                height: 90,
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: .18),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(Icons.play_circle_fill_rounded,
                                    color: Colors.white, size: 50),
                              ),
                              const SizedBox(height: 16),
                              Text(rewardLabel,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 22,
                                      fontWeight: FontWeight.w800)),
                              const SizedBox(height: 6),
                              Text(
                                  'Watch a short video to earn instant BCP. $_remainingToday left today.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                      color: Colors.white.withValues(alpha: .9))),
                            ],
                          ),
                        ),
                        const SizedBox(height: 24),
                        // Daily cycle complete → "come back tomorrow" with a
                        // server-authoritative countdown to the next UTC day.
                        if (cycleComplete)
                          CycleCompleteView(
                            target: _nextCycleAt!,
                            onFinished: _load,
                            title: "Today's ads completed",
                            color: AppColors.success,
                          )
                        // Cooldown line — server-authoritative absolute time, so
                        // it stays correct across app close/reopen.
                        else if (onCooldown)
                          Center(
                            child: CountdownText(
                              target: _nextAt,
                              prefix: 'Next Ad Available in ',
                              onFinished: _load,
                              style: TextStyle(
                                  color: context.cx.textSecondary,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 16),
                              finishedChild: const Text('Next Ad Available',
                                  style: TextStyle(
                                      color: AppColors.success,
                                      fontWeight: FontWeight.w700)),
                            ),
                          )
                        else if (limitReached)
                          Center(
                            child: Text('Come back tomorrow for more ads.',
                                style:
                                    TextStyle(color: context.cx.textSecondary)),
                          ),
                        const SizedBox(height: 12),
                        ElevatedButton.icon(
                          onPressed: (_busy ||
                                  onCooldown ||
                                  limitReached ||
                                  cycleComplete)
                              ? null
                              : _watch,
                          icon: _busy
                              ? const SizedBox(
                                  height: 20,
                                  width: 20,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2.2, color: Colors.white))
                              : const Icon(Icons.smart_display_rounded),
                          label: Text(_busy
                              ? 'Loading ad…'
                              : onCooldown
                                  ? 'Please wait…'
                                  : limitReached
                                      ? 'Daily limit reached'
                                      : 'Watch ad'),
                        ),
                        const SizedBox(height: 16),
                        const _RulesCard(),
                      ],
                    ),
                  ),
      ),
    );
  }
}

class _RulesCard extends StatelessWidget {
  const _RulesCard();

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('How it works',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
          const SizedBox(height: 12),
          _rule(context, Icons.verified_user_rounded,
              'Rewards are granted only after a completed ad — verified on the server.'),
          _rule(context, Icons.timelapse_rounded,
              'A cooldown applies between ads; the timer above is server-controlled.'),
          _rule(context, Icons.today_rounded,
              'There is a daily limit on rewarded ads.'),
        ],
      ),
    );
  }

  Widget _rule(BuildContext context, IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: AppColors.primary),
          const SizedBox(width: 10),
          Expanded(
              child: Text(text,
                  style: TextStyle(color: context.cx.textSecondary))),
        ],
      ),
    );
  }
}
