import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/ad_gate.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/banner_ad_bar.dart';
import '../../../core/widgets/common.dart';
import '../../../core/widgets/countdown.dart';
import '../../../core/widgets/state_views.dart';
import '../../../models/earn_models.dart';
import '../../../providers/data_providers.dart';
import '../../../providers/repositories.dart';
import 'package:bluechip_rewards/core/theme/app_palette.dart';

class MiningScreen extends ConsumerStatefulWidget {
  const MiningScreen({super.key});

  @override
  ConsumerState<MiningScreen> createState() => _MiningScreenState();
}

class _MiningScreenState extends ConsumerState<MiningScreen> {
  Timer? _ticker;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // Local 1s tick to animate the accrual counter between server refreshes.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  /// Estimated live accrual derived from server-authoritative session data.
  int _liveClaimable(MiningStatus s) {
    if (!s.active || s.startedAt == null || s.endsAt == null) return s.claimable;
    final now = DateTime.now().toUtc();
    final end = s.endsAt!.toUtc();
    final start = s.startedAt!.toUtc();
    final cappedNow = now.isAfter(end) ? end : now;
    final hours = cappedNow.difference(start).inSeconds / 3600.0;
    final accrued = (hours * s.ratePerHour).floor();
    return (accrued - (s.accrued - s.claimable)).clamp(0, accrued);
  }

  Future<void> _start(MiningStatus s) async {
    setState(() => _busy = true);
    try {
      String? nonce;
      if (s.startRequiresAd) nonce = await runRewardedGate(ref, 'mining');
      await ref.read(earnRepositoryProvider).startMining(nonce: nonce);
      ref.invalidate(miningStatusProvider);
    } catch (e) {
      if (mounted) showSnack(context, '$e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _boost(MiningStatus s) async {
    setState(() => _busy = true);
    try {
      String? nonce;
      if (s.boostRequiresAd) {
        nonce = await runRewardedGate(ref, 'mining');
      }
      final res =
          await ref.read(earnRepositoryProvider).boostMining(nonce: nonce);
      ref.invalidate(miningStatusProvider);
      if (mounted) {
        final rate = (res['rate_per_hour'] as num?)?.toInt() ?? s.ratePerHour;
        showSnack(context, 'Boost applied! New rate: $rate BCP/hour.');
      }
    } catch (e) {
      if (mounted) showSnack(context, '$e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _claim(MiningStatus s) async {
    setState(() => _busy = true);
    try {
      String? nonce;
      if (s.claimRequiresAd) nonce = await runRewardedGate(ref, 'mining');
      final res =
          await ref.read(earnRepositoryProvider).claimMining(nonce: nonce);
      ref.invalidate(miningStatusProvider);
      ref.invalidate(walletProvider);
      ref.invalidate(transactionsProvider);
      final claimed = (res['claimed'] as num).toInt();
      if (mounted && claimed > 0) {
        await showRewardDialog(context,
            amount: claimed, title: 'Mining reward claimed!');
      } else if (mounted) {
        showSnack(context, 'Session settled.');
      }
    } catch (e) {
      if (mounted) showSnack(context, '$e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final statusAsync = ref.watch(miningStatusProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Mining')),
      bottomNavigationBar: const BannerAdBar(placement: 'mining'),
      body: SafeArea(
        top: false,
        child: statusAsync.when(
          loading: () => const LoadingView(),
          error: (e, _) => ErrorView(
              error: e, onRetry: () => ref.invalidate(miningStatusProvider)),
          data: (s) {
            final claimable = _liveClaimable(s);
            final remaining = (s.active && s.endsAt != null)
                ? s.endsAt!.toUtc().difference(DateTime.now().toUtc())
                : Duration.zero;
            final progress = (s.active && s.startedAt != null && s.endsAt != null)
                ? (DateTime.now()
                            .toUtc()
                            .difference(s.startedAt!.toUtc())
                            .inSeconds /
                        s.endsAt!
                            .toUtc()
                            .difference(s.startedAt!.toUtc())
                            .inSeconds)
                    .clamp(0.0, 1.0)
                : 0.0;

            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _MiningOrb(
                  active: s.active,
                  boostActive: s.boostActive,
                  progress: progress.toDouble(),
                  claimable: claimable,
                  rate: s.ratePerHour,
                ),
                if (s.active && s.boostActive) ...[
                  const SizedBox(height: 14),
                  _BoostActiveBanner(status: s),
                ],
                const SizedBox(height: 24),
                if (s.active) ...[
                  SectionCard(
                    child: Column(
                      children: [
                        _infoRow(Icons.speed_rounded, 'Rate',
                            '${s.ratePerHour} BCP / hour'),
                        const Divider(height: 22),
                        _infoRow(
                            Icons.timer_outlined,
                            s.completed ? 'Status' : 'Time left',
                            s.completed
                                ? 'Session complete'
                                : Fmt.duration(remaining)),
                        const Divider(height: 22),
                        _infoRow(Icons.savings_rounded, 'Claimable now',
                            '$claimable BCP'),
                        const Divider(height: 22),
                        _infoRow(Icons.confirmation_number_outlined,
                            'Claims left', '${s.claimsRemaining} / ${s.maxClaims}'),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  ElevatedButton.icon(
                    onPressed: (_busy || claimable <= 0 || s.claimsRemaining <= 0)
                        ? null
                        : () => _claim(s),
                    icon: _busy
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2.2, color: Colors.white))
                        : const Icon(Icons.download_rounded),
                    label: Text(_busy
                        ? 'Processing…'
                        : s.claimsRemaining <= 0
                            ? 'Claim limit reached'
                            : claimable <= 0
                                ? 'Nothing to claim yet'
                                : s.claimRequiresAd
                                    ? 'Watch ad & claim $claimable BCP'
                                    : 'Claim $claimable BCP'),
                  ),
                  if (!s.completed) ...[
                    const SizedBox(height: 16),
                    _BoostCard(
                      status: s,
                      busy: _busy,
                      onBoost: () => _boost(s),
                    ),
                  ],
                  if (s.completed) ...[
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : () => _start(s),
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('Start a new session'),
                    ),
                  ],
                ] else ...[
                  SectionCard(
                    child: Column(
                      children: [
                        _infoRow(Icons.speed_rounded, 'Rate',
                            '${s.ratePerHour} BCP / hour'),
                        const Divider(height: 22),
                        _infoRow(Icons.hourglass_bottom_rounded, 'Duration',
                            '${s.sessionHours} hours'),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  ElevatedButton.icon(
                    onPressed: (_busy || !s.enabled) ? null : () => _start(s),
                    icon: _busy
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2.2, color: Colors.white))
                        : const Icon(Icons.bolt_rounded),
                    label: Text(!s.enabled
                        ? 'Mining is disabled'
                        : s.startRequiresAd
                            ? 'Watch ad & start mining'
                            : 'Start mining'),
                  ),
                ],
                const SizedBox(height: 14),
                Text(
                  'Mining runs on the server — your BCP keeps accruing even when the app is closed. Come back anytime to claim.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: context.cx.textSecondary, fontSize: 13),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _infoRow(IconData icon, String label, String value) {
    return Row(
      children: [
        Icon(icon, color: AppColors.primary, size: 20),
        const SizedBox(width: 12),
        Text(label, style: TextStyle(color: context.cx.textSecondary)),
        const Spacer(),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w800)),
      ],
    );
  }
}

class _BoostCard extends StatelessWidget {
  final MiningStatus status;
  final bool busy;
  final VoidCallback onBoost;
  const _BoostCard(
      {required this.status, required this.busy, required this.onBoost});

  @override
  Widget build(BuildContext context) {
    final s = status;
    final atMax = s.boosts >= s.maxBoosts;
    final cooling = s.nextBoostAt != null &&
        DateTime.now().toUtc().isBefore(s.nextBoostAt!.toUtc());
    final cooldownLeft = cooling
        ? s.nextBoostAt!.toUtc().difference(DateTime.now().toUtc())
        : Duration.zero;

    String label;
    if (atMax) {
      label = 'All ${s.maxBoosts} boosts used';
    } else if (cooling) {
      label = 'Boost in ${Fmt.duration(cooldownLeft)}';
    } else {
      label = s.boostRequiresAd
          ? 'Watch ad to boost +${s.boostPct}%'
          : 'Boost +${s.boostPct}%';
    }

    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.rocket_launch_rounded, color: AppColors.gold),
              const SizedBox(width: 10),
              const Expanded(
                child: Text('Boost your mining rate',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
              ),
              Pill('${s.boosts}/${s.maxBoosts}', color: AppColors.gold),
            ],
          ),
          const SizedBox(height: 6),
          Text(
              'Each boost adds ${s.boostPct}% of your base rate (${s.baseRate} BCP/hour) for the rest of the session.',
              style: TextStyle(color: context.cx.textSecondary, fontSize: 13)),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: (busy || atMax || cooling || !s.canBoost)
                  ? null
                  : onBoost,
              style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.gold,
                  minimumSize: const Size.fromHeight(46)),
              icon: busy
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.rocket_launch_rounded),
              label: Text(label),
            ),
          ),
        ],
      ),
    );
  }
}

/// Server-driven boost banner: only shown while `boostActive` is true (i.e. the
/// server confirms a live boost). Shows the boosted rate and a countdown to
/// expiry; when it reaches zero the screen reloads and reverts to normal.
class _BoostActiveBanner extends ConsumerWidget {
  final MiningStatus status;
  const _BoostActiveBanner({required this.status});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
            colors: [Color(0xFF7C3AED), Color(0xFF22D3EE)]),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          const Icon(Icons.rocket_launch_rounded, color: Colors.white),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Boost active',
                    style: TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w800)),
                Text('${status.ratePerHour} BCP/hour (base ${status.baseRate})',
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: .9), fontSize: 12)),
              ],
            ),
          ),
          CountdownText(
            target: status.boostEndsAt,
            prefix: '',
            onFinished: () => ref.invalidate(miningStatusProvider),
            style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w900,
                fontSize: 18),
            finishedChild: const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

class _MiningOrb extends StatelessWidget {
  final bool active;
  final bool boostActive;
  final double progress;
  final int claimable;
  final int rate;
  const _MiningOrb({
    required this.active,
    required this.progress,
    required this.claimable,
    required this.rate,
    this.boostActive = false,
  });

  // A distinct boost gradient/color, shown ONLY when a boost is server-verified
  // active — so the colour never changes merely because a button was tapped.
  static const _boostColor = Color(0xFF7C3AED); // violet
  static const _boostGradient = LinearGradient(
    colors: [Color(0xFF7C3AED), Color(0xFF22D3EE)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  @override
  Widget build(BuildContext context) {
    final ringColor = boostActive ? _boostColor : AppColors.gold;
    final centerGradient = boostActive
        ? _boostGradient
        : (active
            ? AppColors.goldGradient
            : LinearGradient(
                colors: [context.cx.surfaceAlt, context.cx.surfaceAlt]));
    return Center(
      child: SizedBox(
        width: 220,
        height: 220,
        child: Stack(
          alignment: Alignment.center,
          children: [
            SizedBox(
              width: 220,
              height: 220,
              child: CircularProgressIndicator(
                value: active ? progress : 0,
                strokeWidth: 12,
                backgroundColor: context.cx.surfaceAlt,
                valueColor: AlwaysStoppedAnimation(ringColor),
              ),
            ),
            Container(
              width: 168,
              height: 168,
              decoration: BoxDecoration(gradient: centerGradient, shape: BoxShape.circle),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(boostActive ? Icons.rocket_launch_rounded : Icons.bolt_rounded,
                      size: 40,
                      color: active ? Colors.white : context.cx.textSecondary),
                  const SizedBox(height: 6),
                  Text(active ? '$claimable' : 'Idle',
                      style: TextStyle(
                          fontSize: active ? 34 : 24,
                          fontWeight: FontWeight.w900,
                          color:
                              active ? Colors.white : context.cx.textSecondary)),
                  Text(boostActive
                          ? 'BOOST ACTIVE'
                          : (active ? 'BCP mined' : 'Tap start below'),
                      style: TextStyle(
                          color: active
                              ? Colors.white.withValues(alpha: .9)
                              : context.cx.textSecondary,
                          fontSize: 12,
                          fontWeight:
                              boostActive ? FontWeight.w800 : FontWeight.w400,
                          letterSpacing: boostActive ? 1 : 0)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
