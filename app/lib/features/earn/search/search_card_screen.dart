import 'dart:math' as math;

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

/// Search Card — the user performs a search, sees a result, then (if the admin
/// requires it) completes a rewarded ad; the server verifies and credits a
/// random reward within the applicable rule's range. Searching alone never
/// credits BCP — only the server-side reward step does.
class SearchCardScreen extends ConsumerStatefulWidget {
  const SearchCardScreen({super.key});

  @override
  ConsumerState<SearchCardScreen> createState() => _SearchCardScreenState();
}

enum _Phase { idle, searching, result, rewarding, done }

class _SearchCardScreenState extends ConsumerState<SearchCardScreen> {
  bool _loading = true;
  String? _error;
  Map<String, dynamic> _status = const {};
  List<Map<String, dynamic>> _rules = const [];
  _Phase _phase = _Phase.idle;
  int? _amount;

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
      _phase = _Phase.idle;
      _amount = null;
    });
    try {
      final repo = ref.read(earnRepositoryProvider);
      try {
        final cfg = await repo.searchCardConfig();
        _rules = ((cfg['rules'] as List?) ?? const [])
            .map((e) => (e as Map).cast<String, dynamic>())
            .toList();
      } catch (_) {}
      final s = await repo.searchCardStatus();
      if (mounted) setState(() => _status = s);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  int get _min => (_status['min_reward'] as num?)?.toInt() ?? 0;
  int get _max => (_status['max_reward'] as num?)?.toInt() ?? 0;
  int get _remaining => (_status['remaining_today'] as num?)?.toInt() ?? -1;
  bool get _available => _status['available'] == true;
  bool get _hasRule => _status['has_rule'] == true;
  bool get _adRequired => _status['ad_required'] == true;
  DateTime? get _nextAt {
    final s = _status['next_available_at'];
    if (s is String && s.isNotEmpty) return DateTime.tryParse(s);
    return null;
  }

  Future<void> _search() async {
    if (_phase != _Phase.idle || !_available) return;
    // 1) Show a search result (cosmetic — grants nothing on its own).
    setState(() => _phase = _Phase.searching);
    await Future.delayed(const Duration(milliseconds: 900));
    if (!mounted) return;
    setState(() => _phase = _Phase.result);
  }

  Future<void> _claimReward() async {
    if (_phase != _Phase.result) return;
    setState(() => _phase = _Phase.rewarding);
    try {
      String? nonce;
      if (_adRequired) {
        // Rewarded ad required → must be completed & verified.
        nonce = await runRewardedGate(ref, 'search');
        if (nonce == null) {
          // Admin disabled the ad after status loaded → proceed without one;
          // the server also treats it as ungated.
        }
      }
      final res =
          await ref.read(earnRepositoryProvider).searchCardReward(nonce: nonce);
      ref.invalidate(walletProvider);
      ref.invalidate(transactionsProvider);
      if (mounted) {
        setState(() {
          _amount = (res['amount'] as num).toInt();
          _phase = _Phase.done;
        });
      }
    } catch (e) {
      if (mounted) {
        showSnack(context, _friendly('$e'), error: true);
        setState(() => _phase = _Phase.result);
      }
    }
  }

  String _friendly(String e) {
    if (e.contains('SEARCH_TOO_SOON')) return 'Please wait for the cooldown to finish.';
    if (e.contains('SEARCH_DAILY_LIMIT')) return 'You have reached today\'s search limit.';
    if (e.contains('AD_')) return 'Watch the full ad to claim your reward.';
    return e;
  }

  @override
  Widget build(BuildContext context) {
    final onCooldown = !_available && _nextAt != null;
    final limitReached = _remaining == 0 && !_available;
    final rewardLabel = _max <= 0
        ? 'Search & earn'
        : (_min == _max ? 'Earn up to $_max BCP' : 'Earn $_min–$_max BCP');

    return Scaffold(
      appBar: AppBar(title: const Text('Search Card')),
      bottomNavigationBar: const BannerAdBar(placement: 'search'),
      body: SafeArea(
        top: false,
        child: _loading
            ? const LoadingView()
            : _error != null
                ? ErrorView(error: _error!, onRetry: _load)
                : ListView(
                    padding: const EdgeInsets.all(20),
                    children: [
                      SectionCard(
                        gradient: const LinearGradient(
                          colors: [AppColors.info, Color(0xFF60A5FA)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          children: [
                            const Icon(Icons.travel_explore_rounded,
                                color: Colors.white, size: 54),
                            const SizedBox(height: 12),
                            Text(rewardLabel,
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 22,
                                    fontWeight: FontWeight.w800)),
                            const SizedBox(height: 4),
                            Text(
                                _adRequired
                                    ? 'Search, then watch a short ad to claim.'
                                    : 'Search to reveal your reward.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    color: Colors.white.withValues(alpha: .9))),
                          ],
                        ),
                      ),
                      if (_rules.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          alignment: WrapAlignment.center,
                          children: [
                            for (final r in _rules)
                              Pill(
                                  'Searches ${r['from_search']}–${r['to_search']}: ${r['min']}–${r['max']} BCP',
                                  color: AppColors.info),
                          ],
                        ),
                      ],
                      const SizedBox(height: 24),
                      _center(onCooldown, limitReached),
                    ],
                  ),
      ),
    );
  }

  Widget _center(bool onCooldown, bool limitReached) {
    if (!_hasRule) {
      return const EmptyView(
          icon: Icons.travel_explore_rounded,
          title: 'Search Card is not configured',
          subtitle: 'Please check back soon.');
    }
    if (onCooldown) {
      return Column(
        children: [
          Text('Next Search Available in',
              style: TextStyle(color: context.cx.textSecondary)),
          const SizedBox(height: 6),
          CountdownText(
            target: _nextAt,
            onFinished: _load,
            style: const TextStyle(
                fontSize: 30, fontWeight: FontWeight.w900, color: AppColors.info),
            finishedChild: const Text('Search Available',
                style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: AppColors.success)),
          ),
        ],
      );
    }
    if (limitReached) {
      return Center(
        child: Text('Come back tomorrow for more searches.',
            style: TextStyle(color: context.cx.textSecondary)),
      );
    }

    switch (_phase) {
      case _Phase.idle:
        return Center(
          child: ElevatedButton.icon(
            onPressed: _search,
            style:
                ElevatedButton.styleFrom(minimumSize: const Size(220, 50)),
            icon: const Icon(Icons.search_rounded),
            label: const Text('Search'),
          ),
        );
      case _Phase.searching:
        return const _SearchingCard();
      case _Phase.result:
        return Column(
          children: [
            const _ResultCard(),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _claimReward,
              style: ElevatedButton.styleFrom(minimumSize: const Size(220, 50)),
              icon: Icon(
                  _adRequired ? Icons.smart_display_rounded : Icons.redeem_rounded),
              label: Text(_adRequired ? 'Watch ad & claim' : 'Claim reward'),
            ),
          ],
        );
      case _Phase.rewarding:
        return const Center(child: CircularProgressIndicator());
      case _Phase.done:
        return Column(
          children: [
            Icon(Icons.verified_rounded, color: AppColors.success, size: 56),
            const SizedBox(height: 10),
            Text('+$_amount BCP',
                style: const TextStyle(
                    fontSize: 34,
                    fontWeight: FontWeight.w900,
                    color: AppColors.success)),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Continue'),
            ),
          ],
        );
    }
  }
}

class _SearchingCard extends StatelessWidget {
  const _SearchingCard();
  @override
  Widget build(BuildContext context) => Column(
        children: [
          const SizedBox(
              height: 60,
              width: 60,
              child: CircularProgressIndicator(strokeWidth: 3)),
          const SizedBox(height: 14),
          Text('Searching…', style: TextStyle(color: context.cx.textSecondary)),
        ],
      );
}

class _ResultCard extends StatelessWidget {
  const _ResultCard();
  @override
  Widget build(BuildContext context) {
    final idx = math.Random().nextInt(3);
    const labels = ['Card found! 🎯', 'Match found! 🔍', 'You found a card! ✨'];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 22),
      decoration: BoxDecoration(
        color: AppColors.info.withValues(alpha: .10),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.info.withValues(alpha: .35)),
      ),
      child: Column(
        children: [
          const Icon(Icons.check_circle_rounded, color: AppColors.info, size: 44),
          const SizedBox(height: 8),
          Text(labels[idx],
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text('Claim your reward below.',
              style: TextStyle(color: context.cx.textSecondary)),
        ],
      ),
    );
  }
}
