import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/common.dart';
import '../../../core/widgets/state_views.dart';
import '../../../providers/data_providers.dart';
import '../../../providers/repositories.dart';
import 'package:bluechip_rewards/core/theme/app_palette.dart';

/// The reward is decided server-side when the card is issued (scratch_status);
/// revealing calls scratch_reveal which credits the ledger. The client cannot
/// influence the amount.
class ScratchScreen extends ConsumerStatefulWidget {
  const ScratchScreen({super.key});

  @override
  ConsumerState<ScratchScreen> createState() => _ScratchScreenState();
}

class _ScratchScreenState extends ConsumerState<ScratchScreen> {
  bool _loading = true;
  bool _revealing = false;
  bool _revealed = false;
  String? _cardId;
  int? _amount;
  int _remaining = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _revealed = false;
      _amount = null;
      _error = null;
    });
    try {
      final res = await ref.read(earnRepositoryProvider).scratchStatus();
      setState(() {
        _cardId = res['card_id'] as String?;
        _remaining = (res['remaining_today'] as num?)?.toInt() ?? 0;
      });
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _reveal() async {
    if (_cardId == null || _revealing) return;
    setState(() => _revealing = true);
    try {
      final res =
          await ref.read(earnRepositoryProvider).scratchReveal(_cardId!);
      ref.invalidate(walletProvider);
      ref.invalidate(transactionsProvider);
      setState(() {
        _amount = (res['amount'] as num).toInt();
        _revealed = true;
      });
    } catch (e) {
      if (mounted) showSnack(context, '$e', error: true);
    } finally {
      if (mounted) setState(() => _revealing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scratch Card')),
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
                        const SizedBox(height: 12),
                        Text(
                          _cardId == null
                              ? 'No scratch cards left today'
                              : 'Tap the card to reveal your prize',
                          style: TextStyle(
                              color: context.cx.textSecondary, fontSize: 15),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 24),
                        Expanded(
                          child: Center(
                            child: _cardId == null
                                ? const EmptyView(
                                    icon: Icons.card_giftcard_rounded,
                                    title: 'Come back tomorrow',
                                    subtitle:
                                        'New scratch cards are issued daily.',
                                  )
                                : _card(),
                          ),
                        ),
                        if (_cardId != null && !_revealed)
                          Text('$_remaining more today',
                              style: TextStyle(
                                  color: context.cx.textSecondary)),
                        if (_revealed) ...[
                          const SizedBox(height: 12),
                          _remaining > 0
                              ? ElevatedButton.icon(
                                  onPressed: _load,
                                  icon: const Icon(Icons.refresh_rounded),
                                  label: Text(
                                      'Next card ($_remaining left today)'),
                                )
                              : const Text('That\'s all for today. See you tomorrow!'),
                        ],
                        const SizedBox(height: 12),
                      ],
                    ),
                  ),
      ),
    );
  }

  Widget _card() {
    return GestureDetector(
      onTap: _revealed ? null : _reveal,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 400),
        width: 260,
        height: 320,
        decoration: BoxDecoration(
          gradient: _revealed
              ? AppColors.goldGradient
              : const LinearGradient(
                  colors: [Color(0xFF94A3B8), Color(0xFFCBD5E1)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withOpacity(.12),
                blurRadius: 24,
                offset: const Offset(0, 12)),
          ],
        ),
        child: Center(
          child: _revealing
              ? const CircularProgressIndicator(color: Colors.white)
              : _revealed
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
                        Icon(Icons.touch_app_rounded,
                            color: Colors.white, size: 60),
                        SizedBox(height: 12),
                        Text('SCRATCH\nHERE',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 22,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 2)),
                      ],
                    ),
        ),
      ),
    );
  }
}
