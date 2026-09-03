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

/// Admin-rule-driven scratch: the server decides eligibility, ads required,
/// the Search-Card delay, the cooldown and the reward (random within the rule's
/// range). The client only reflects that state and shows live countdowns.
class ScratchScreen extends ConsumerStatefulWidget {
  const ScratchScreen({super.key});

  @override
  ConsumerState<ScratchScreen> createState() => _ScratchScreenState();
}

enum _Phase { idle, watchingAds, searchDelay, revealing, revealed }

class _ScratchScreenState extends ConsumerState<ScratchScreen> {
  bool _loading = true;
  String? _error;
  Map<String, dynamic> _status = const {};
  List<Map<String, dynamic>> _rules = const [];

  _Phase _phase = _Phase.idle;
  final List<String> _nonces = [];
  DateTime? _searchUntil;
  int? _amount;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _phase = _Phase.idle;
      _nonces.clear();
      _searchUntil = null;
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
      if (mounted) setState(() => _status = s);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String? get _cardId => _status['card_id'] as String?;
  bool get _available => _status['available'] == true && _cardId != null;
  int get _adsRequired => (_status['ads_required'] as num?)?.toInt() ?? 1;
  int get _searchDelay => (_status['search_delay_seconds'] as num?)?.toInt() ?? 0;
  DateTime? get _nextAt {
    final s = _status['next_available_at'];
    if (s is String && s.isNotEmpty) return DateTime.tryParse(s);
    return null;
  }

  Future<void> _startScratch() async {
    if (_cardId == null || _phase != _Phase.idle) return;
    // 1) Watch the required number of rewarded ads, collecting nonces. If the
    // admin has disabled rewarded ads (master/section OFF), runRewardedGate
    // returns null and we reveal directly — the server also skips the ad
    // requirement in that case, so no ad is required anywhere.
    _nonces.clear();
    var adsSkipped = false;
    if (_adsRequired > 0) {
      setState(() => _phase = _Phase.watchingAds);
      for (var i = 0; i < _adsRequired; i++) {
        String? nonce;
        try {
          nonce = await runRewardedGate(ref, 'scratch');
        } catch (e) {
          if (mounted) showSnack(context, '$e', error: true);
          setState(() => _phase = _Phase.idle);
          return;
        }
        if (nonce == null) {
          // Rewarded ads disabled by admin → skip ads and reveal directly.
          adsSkipped = true;
          _nonces.clear();
          break;
        }
        _nonces.add(nonce);
      }
    }
    // 2) Search-Card delay countdown (only when an ad was actually watched),
    // then reveal.
    if (!adsSkipped && _searchDelay > 0) {
      setState(() {
        _phase = _Phase.searchDelay;
        _searchUntil = DateTime.now().add(Duration(seconds: _searchDelay));
      });
    } else {
      _reveal();
    }
  }

  Future<void> _reveal() async {
    if (_cardId == null) return;
    setState(() => _phase = _Phase.revealing);
    try {
      final res = await ref
          .read(earnRepositoryProvider)
          .scratchReveal(_cardId!, nonces: List<String>.from(_nonces));
      ref.invalidate(walletProvider);
      ref.invalidate(transactionsProvider);
      if (mounted) {
        setState(() {
          _amount = (res['amount'] as num).toInt();
          _phase = _Phase.revealed;
        });
      }
    } catch (e) {
      if (mounted) {
        showSnack(context, _friendly('$e'), error: true);
        setState(() => _phase = _Phase.idle);
      }
    }
  }

  String _friendly(String e) {
    if (e.contains('SEARCH_DELAY_ACTIVE')) {
      return 'Please wait for the Search Card delay to finish.';
    }
    if (e.contains('AD_REQUIRED')) return 'Please watch the required ad(s) first.';
    if (e.contains('AD_ALREADY_USED')) return 'That ad was already used.';
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
    // Cooldown → countdown to the next scratch.
    if (!_available && _nextAt != null) {
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

    // Search-Card delay countdown.
    if (_phase == _Phase.searchDelay) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.search_rounded, size: 56, color: AppColors.primary),
          const SizedBox(height: 16),
          Text('Search Card available in',
              style: TextStyle(color: context.cx.textSecondary)),
          const SizedBox(height: 6),
          CountdownText(
            target: _searchUntil,
            onFinished: _reveal,
            style: const TextStyle(
                fontSize: 34, fontWeight: FontWeight.w900, color: AppColors.primary),
            finishedChild: const Text('Revealing…',
                style: TextStyle(fontWeight: FontWeight.w700)),
          ),
        ],
      );
    }

    // The card + scratch button.
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _card(),
        const SizedBox(height: 20),
        if (_phase == _Phase.idle)
          ElevatedButton.icon(
            onPressed: _startScratch,
            icon: const Icon(Icons.smart_display_rounded),
            label: Text(_adsRequired > 0
                ? 'Watch ${_adsRequired == 1 ? 'ad' : '$_adsRequired ads'} & scratch'
                : 'Scratch now'),
          )
        else if (_phase == _Phase.watchingAds)
          const Text('Loading ad…', style: TextStyle(fontWeight: FontWeight.w600))
        else if (_phase == _Phase.revealed && _amount != null)
          ElevatedButton.icon(
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Continue'),
          ),
      ],
    );
  }

  Widget _card() {
    final revealed = _phase == _Phase.revealed;
    final revealing = _phase == _Phase.revealing;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      width: 240,
      height: 280,
      decoration: BoxDecoration(
        gradient: revealed
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
        child: revealing
            ? const CircularProgressIndicator(color: Colors.white)
            : revealed
                ? Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.emoji_events_rounded,
                          color: Colors.white, size: 60),
                      const SizedBox(height: 12),
                      Text('+$_amount',
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 48,
                              fontWeight: FontWeight.w900)),
                      const Text('BCP',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w700)),
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
