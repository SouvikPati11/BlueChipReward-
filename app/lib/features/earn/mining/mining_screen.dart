import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/common.dart';
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

  Future<void> _start() async {
    setState(() => _busy = true);
    try {
      await ref.read(earnRepositoryProvider).startMining();
      ref.invalidate(miningStatusProvider);
    } catch (e) {
      if (mounted) showSnack(context, '$e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _claim() async {
    setState(() => _busy = true);
    try {
      final res = await ref.read(earnRepositoryProvider).claimMining();
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
                  progress: progress.toDouble(),
                  claimable: claimable,
                  rate: s.ratePerHour,
                ),
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
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  ElevatedButton.icon(
                    onPressed: (_busy || claimable <= 0) ? null : _claim,
                    icon: const Icon(Icons.download_rounded),
                    label: Text(claimable > 0
                        ? 'Claim $claimable BCP'
                        : 'Nothing to claim yet'),
                  ),
                  if (s.completed) ...[
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _start,
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
                    onPressed: _busy ? null : _start,
                    icon: _busy
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2.2, color: Colors.white))
                        : const Icon(Icons.bolt_rounded),
                    label: const Text('Start mining'),
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

class _MiningOrb extends StatelessWidget {
  final bool active;
  final double progress;
  final int claimable;
  final int rate;
  const _MiningOrb({
    required this.active,
    required this.progress,
    required this.claimable,
    required this.rate,
  });

  @override
  Widget build(BuildContext context) {
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
                valueColor:
                    const AlwaysStoppedAnimation(AppColors.gold),
              ),
            ),
            Container(
              width: 168,
              height: 168,
              decoration: BoxDecoration(
                gradient: active
                    ? AppColors.goldGradient
                    : LinearGradient(colors: [
                        context.cx.surfaceAlt,
                        context.cx.surfaceAlt
                      ]),
                shape: BoxShape.circle,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.bolt_rounded,
                      size: 40,
                      color: active ? Colors.white : context.cx.textSecondary),
                  const SizedBox(height: 6),
                  Text(active ? '$claimable' : 'Idle',
                      style: TextStyle(
                          fontSize: active ? 34 : 24,
                          fontWeight: FontWeight.w900,
                          color:
                              active ? Colors.white : context.cx.textSecondary)),
                  Text(active ? 'BCP mined' : 'Tap start below',
                      style: TextStyle(
                          color: active
                              ? Colors.white.withValues(alpha: .9)
                              : context.cx.textSecondary,
                          fontSize: 12)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
