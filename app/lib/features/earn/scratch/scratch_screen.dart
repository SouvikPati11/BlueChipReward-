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

/// Scratch Card — server-authoritative, ad-gated, duplicate-safe.
///
/// Flow (matches Search Card semantics): the screen shows the possible reward
/// RANGE before scratching; the user scratches to REVEAL the exact amount the
/// server already decided (nothing is credited yet); then a single rewarded ad
/// is required; only after the ad completes does the server verify and CREDIT
/// that exact amount to the wallet/ledger. When the Reward-ads master is off,
/// no ad is required and the reveal is credited directly.
class ScratchScreen extends ConsumerStatefulWidget {
  const ScratchScreen({super.key});

  @override
  ConsumerState<ScratchScreen> createState() => _ScratchScreenState();
}

enum _Phase { idle, revealing, revealed, claiming, done }

class _ScratchScreenState extends ConsumerState<ScratchScreen> {
  bool _loading = true;
  String? _error;
  Map<String, dynamic> _status = const {};
  List<Map<String, dynamic>> _rules = const [];

  _Phase _phase = _Phase.idle;
  int? _amount; // the revealed / credited amount

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
        final cfg = await repo.scratchConfig();
        _rules = ((cfg['rules'] as List?) ?? const [])
            .map((e) => (e as Map).cast<String, dynamic>())
            .toList();
      } catch (_) {}
      final s = await repo.scratchStatus();
      if (mounted) {
        setState(() {
          _status = s;
          // Resume the claim step if the card was already revealed (e.g. the
          // user revealed, then closed the app before watching the ad).
          if (s['revealed'] == true && s['amount'] != null) {
            _amount = (s['amount'] as num).toInt();
            _phase = _Phase.revealed;
          }
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String? get _cardId => _status['card_id'] as String?;
  bool get _available => _status['available'] == true && _cardId != null;
  bool get _adRequired => _status['ad_required'] == true;
  bool get _cycleComplete => _status['cycle_complete'] == true;
  int get _min => (_status['min_reward'] as num?)?.toInt() ?? 0;
  int get _max => (_status['max_reward'] as num?)?.toInt() ?? 0;

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

  /// Step 1 — scratch to reveal the exact amount (no ad, no credit yet).
  Future<void> _reveal() async {
    if (_cardId == null || _phase != _Phase.idle) return;
    setState(() => _phase = _Phase.revealing);
    try {
      final res = await ref.read(earnRepositoryProvider).scratchReveal(_cardId!);
      if (!mounted) return;
      // If the server says it was already credited, jump to done.
      final credited = res['credited'] == true;
      setState(() {
        _amount = (res['amount'] as num).toInt();
        _phase = credited ? _Phase.done : _Phase.revealed;
      });
      if (credited) {
        ref.invalidate(walletProvider);
        ref.invalidate(transactionsProvider);
      }
    } catch (e) {
      if (mounted) {
        showSnack(context, _friendly('$e'), error: true);
        setState(() => _phase = _Phase.idle);
      }
    }
  }

  /// Step 2 — watch the required rewarded ad, then the server verifies it and
  /// credits the exact revealed amount. Nothing is credited without the ad
  /// (unless the Reward-ads master is off, in which case no ad is required).
  Future<void> _claim() async {
    if (_cardId == null || _phase != _Phase.revealed) return;
    setState(() => _phase = _Phase.claiming);
    try {
      String? nonce;
      if (_adRequired) {
        nonce = await runRewardedGate(ref, 'scratch');
        // nonce == null → admin disabled rewarded ads after status loaded; the
        // server also treats it as ungated, so we proceed and it credits.
      }
      final res = await ref
          .read(earnRepositoryProvider)
          .scratchClaim(_cardId!, nonce: nonce);
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
        setState(() => _phase = _Phase.revealed); // let them retry the ad
      }
    }
  }

  String _friendly(String e) {
    if (e.contains('AD_REQUIRED')) return 'Watch the full ad to claim your reward.';
    if (e.contains('AD_NOT_COMPLETED')) {
      return 'Please watch the full ad to claim your reward.';
    }
    if (e.contains('AD_ALREADY_USED')) return 'That ad was already used.';
    if (e.contains('AD_DAILY_LIMIT')) return 'You have reached today\'s ad limit.';
    if (e.contains('NOT_REVEALED')) return 'Scratch the card first.';
    if (e.contains('CARD_NOT_FOUND')) return 'This card is no longer available.';
    return e;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scratch Card')),
      bottomNavigationBar: const BannerAdBar(placement: 'scratch'),
      body: SafeArea(
        top: false,
        child: _loading
            ? const LoadingView()
            : _error != null
                ? ErrorView(error: _error!, onRetry: _load)
                : Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      children: [
                        const SizedBox(height: 8),
                        if (_rules.isNotEmpty) _rangesRow(),
                        const SizedBox(height: 16),
                        Expanded(child: Center(child: _center())),
                        const SizedBox(height: 12),
                      ],
                    ),
                  ),
      ),
    );
  }

  Widget _rangesRow() => Wrap(
        spacing: 8,
        runSpacing: 8,
        alignment: WrapAlignment.center,
        children: [
          for (final r in _rules)
            Pill(
                'Cards ${r['from_card']}–${r['to_card']}: ${r['min']}–${r['max']} BCP',
                color: AppColors.gold),
        ],
      );

  Widget _center() {
    // Daily cycle complete → come back tomorrow.
    if (_cycleComplete && _nextCycleAt != null) {
      return CycleCompleteView(
        target: _nextCycleAt!,
        onFinished: _load,
        title: 'All Scratch Cards completed for today',
        color: AppColors.gold,
      );
    }

    // Cooldown → countdown to the next scratch.
    if (!_available && _nextAt != null && _phase == _Phase.idle) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.hourglass_bottom_rounded,
              size: 56, color: AppColors.gold),
          const SizedBox(height: 16),
          Text('Next Scratch Available in',
              style: TextStyle(color: context.cx.textSecondary)),
          const SizedBox(height: 6),
          CountdownText(
            target: _nextAt,
            onFinished: _load,
            style: const TextStyle(
                fontSize: 34, fontWeight: FontWeight.w900, color: AppColors.gold),
            finishedChild: const Text('Scratch Card Available',
                style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: AppColors.success)),
          ),
        ],
      );
    }

    // No card and no cooldown → nothing to offer right now.
    if (_cardId == null) {
      return const EmptyView(
        icon: Icons.card_giftcard_rounded,
        title: 'No scratch card right now',
        subtitle: 'Check back soon — new cards unlock on a schedule.',
      );
    }

    final revealedOrLater =
        _phase == _Phase.revealed || _phase == _Phase.claiming || _phase == _Phase.done;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Before scratching: show the possible reward range for this card.
        if (_phase == _Phase.idle && _max > 0) ...[
          Text(_min == _max ? 'Win $_max BCP' : 'Win $_min–$_max BCP',
              style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                  color: AppColors.gold)),
          const SizedBox(height: 14),
        ],
        _card(revealedOrLater),
        const SizedBox(height: 20),
        if (_phase == _Phase.idle)
          ElevatedButton.icon(
            onPressed: _reveal,
            icon: const Icon(Icons.auto_awesome_rounded),
            label: const Text('Scratch'),
          )
        else if (_phase == _Phase.revealing)
          const Text('Revealing…', style: TextStyle(fontWeight: FontWeight.w600))
        else if (_phase == _Phase.revealed)
          Column(
            children: [
              Text(
                  _adRequired
                      ? 'Watch a short ad to claim your $_amount BCP.'
                      : 'Claim your $_amount BCP.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: context.cx.textSecondary)),
              const SizedBox(height: 10),
              ElevatedButton.icon(
                onPressed: _claim,
                icon: Icon(_adRequired
                    ? Icons.smart_display_rounded
                    : Icons.redeem_rounded),
                label: Text(_adRequired ? 'Watch ad & claim' : 'Claim reward'),
              ),
            ],
          )
        else if (_phase == _Phase.claiming)
          const Text('Loading ad…', style: TextStyle(fontWeight: FontWeight.w600))
        else if (_phase == _Phase.done)
          Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.verified_rounded,
                      color: AppColors.success, size: 22),
                  const SizedBox(width: 6),
                  Text('$_amount BCP credited',
                      style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          color: AppColors.success)),
                ],
              ),
              const SizedBox(height: 10),
              ElevatedButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Continue'),
              ),
            ],
          ),
      ],
    );
  }

  /// [showAmount] when the card should display the revealed amount (revealed /
  /// claiming / done); otherwise the face-down "SCRATCH CARD".
  Widget _card(bool showAmount) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      width: 240,
      height: 280,
      decoration: BoxDecoration(
        gradient: showAmount
            ? AppColors.goldGradient
            : const LinearGradient(
                colors: [Color(0xFF94A3B8), Color(0xFFCBD5E1)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: .12),
              blurRadius: 24,
              offset: const Offset(0, 12)),
        ],
      ),
      child: Center(
        child: _phase == _Phase.revealing
            ? const CircularProgressIndicator(color: Colors.white)
            : showAmount
                ? Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.emoji_events_rounded,
                          color: Colors.white, size: 60),
                      const SizedBox(height: 12),
                      Text('+${_amount ?? 0}',
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 48,
                              fontWeight: FontWeight.w900)),
                      const Text('BCP',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w700)),
                      if (_phase == _Phase.revealed)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                              _adRequired ? 'Watch ad to claim' : 'Tap to claim',
                              style: const TextStyle(
                                  color: Colors.white70,
                                  fontWeight: FontWeight.w600)),
                        ),
                    ],
                  )
                : Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: const [
                      Icon(Icons.card_giftcard_rounded,
                          color: Colors.white, size: 60),
                      SizedBox(height: 12),
                      Text('SCRATCH\nCARD',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 22,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 2)),
                    ],
                  ),
      ),
    );
  }
}
