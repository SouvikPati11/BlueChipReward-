import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/common.dart';
import '../../core/widgets/state_views.dart';
import '../../models/wallet_models.dart';
import '../../providers/data_providers.dart';
import '../../providers/repositories.dart';
import 'package:bluechip_rewards/core/theme/app_palette.dart';

class WithdrawScreen extends ConsumerStatefulWidget {
  const WithdrawScreen({super.key});

  @override
  ConsumerState<WithdrawScreen> createState() => _WithdrawScreenState();
}

class _WithdrawScreenState extends ConsumerState<WithdrawScreen> {
  final _form = GlobalKey<FormState>();
  final _amount = TextEditingController();
  final Map<String, TextEditingController> _fieldCtrls = {};
  PaymentMethod? _method;
  bool _submitting = false;
  Map<String, dynamic>? _quote;
  int _quoteSeq = 0;

  @override
  void dispose() {
    _amount.dispose();
    for (final c in _fieldCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _ctrl(String key) =>
      _fieldCtrls.putIfAbsent(key, () => TextEditingController());

  /// Fetch the server-authoritative conversion + fee breakdown.
  Future<void> _refreshQuote() async {
    final amount = int.tryParse(_amount.text.trim()) ?? 0;
    if (_method == null || amount <= 0) {
      setState(() => _quote = null);
      return;
    }
    final seq = ++_quoteSeq;
    try {
      final q = await ref
          .read(walletRepositoryProvider)
          .withdrawalQuote(_method!.key, amount);
      if (mounted && seq == _quoteSeq) setState(() => _quote = q);
    } catch (_) {
      if (mounted && seq == _quoteSeq) setState(() => _quote = null);
    }
  }

  Future<void> _submit(int balance, int minAmount) async {
    if (!_form.currentState!.validate() || _method == null) return;
    final amount = int.tryParse(_amount.text.trim()) ?? 0;
    if (amount > balance) {
      showSnack(context, 'Amount exceeds your balance', error: true);
      return;
    }
    setState(() => _submitting = true);
    try {
      final details = {
        for (final f in _method!.fields) f.key: _ctrl(f.key).text.trim(),
      };
      await ref.read(walletRepositoryProvider).requestWithdrawal(
            amount: amount,
            methodKey: _method!.key,
            details: details,
          );
      ref.invalidate(walletProvider);
      ref.invalidate(withdrawalsProvider);
      ref.invalidate(transactionsProvider);
      if (mounted) {
        showSnack(context, 'Withdrawal request submitted for review');
        context.go('/withdrawals');
      }
    } catch (e) {
      if (mounted) showSnack(context, '$e', error: true);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final walletAsync = ref.watch(walletProvider);
    final methodsAsync = ref.watch(paymentMethodsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Withdraw BCP')),
      body: SafeArea(
        top: false,
        child: walletAsync.when(
          loading: () => const LoadingView(),
          error: (e, _) =>
              ErrorView(error: e, onRetry: () => ref.invalidate(walletProvider)),
          data: (wallet) => methodsAsync.when(
            loading: () => const LoadingView(),
            error: (e, _) => ErrorView(
                error: e,
                onRetry: () => ref.invalidate(paymentMethodsProvider)),
            data: (methods) {
              final minAmount = _method?.minAmount ?? 1000;
              return Form(
                key: _form,
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    SectionCard(
                      color: context.cx.surfaceAlt,
                      child: Row(
                        children: [
                          const Icon(Icons.account_balance_wallet_rounded,
                              color: AppColors.primary),
                          const SizedBox(width: 12),
                          const Text('Available balance'),
                          const Spacer(),
                          Text(Fmt.points(wallet.balance),
                              style: const TextStyle(
                                  fontWeight: FontWeight.w900, fontSize: 18)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    const Text('Amount (BCP)',
                        style: TextStyle(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: _amount,
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly
                      ],
                      decoration: InputDecoration(
                        hintText: 'Min ${_method?.minAmount ?? 1000}',
                        prefixIcon: const Icon(Icons.numbers_rounded),
                      ),
                      onChanged: (_) => _refreshQuote(),
                      validator: (v) {
                        final a = int.tryParse(v ?? '') ?? 0;
                        if (a <= 0) return 'Enter an amount';
                        if (_method != null && a < _method!.minAmount) {
                          return 'Minimum is ${_method!.minAmount}';
                        }
                        if (a > wallet.balance) return 'Exceeds balance';
                        return null;
                      },
                    ),
                    const SizedBox(height: 20),
                    const Text('Payment method',
                        style: TextStyle(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 8),
                    ...methods.map((m) => RadioListTile<PaymentMethod>(
                          value: m,
                          groupValue: _method,
                          onChanged: (v) {
                            setState(() => _method = v);
                            _refreshQuote();
                          },
                          title: Text(m.name),
                          subtitle: Text('Min ${m.minAmount} BCP'),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                            side: BorderSide(
                                color: _method == m
                                    ? AppColors.primary
                                    : context.cx.border),
                          ),
                        )),
                    if (_method != null) ...[
                      const SizedBox(height: 12),
                      const Text('Payment details',
                          style: TextStyle(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 8),
                      for (final f in _method!.fields)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: TextFormField(
                            controller: _ctrl(f.key),
                            keyboardType: f.type == 'phone'
                                ? TextInputType.phone
                                : TextInputType.text,
                            decoration:
                                InputDecoration(labelText: f.label),
                            validator: (v) => (v == null || v.trim().isEmpty)
                                ? 'Required'
                                : null,
                          ),
                        ),
                    ],
                    if (_quote != null) ...[
                      const SizedBox(height: 16),
                      _QuoteCard(quote: _quote!),
                    ],
                    const SizedBox(height: 12),
                    SectionCard(
                      color: AppColors.warning.withValues(alpha: .08),
                      child: Row(
                        children: [
                          const Icon(Icons.info_outline_rounded,
                              color: AppColors.warning),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'Withdrawals are reviewed manually by our team. Your balance is held while the request is pending.',
                              style: TextStyle(
                                  color: context.cx.textSecondary,
                                  fontSize: 13),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: (_submitting || _method == null)
                          ? null
                          : () => _submit(wallet.balance, minAmount),
                      child: _submitting
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2.2, color: Colors.white))
                          : const Text('Submit request'),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Server-authoritative conversion + fee breakdown.
class _QuoteCard extends StatelessWidget {
  final Map<String, dynamic> quote;
  const _QuoteCard({required this.quote});

  String _money(String cur, num v) {
    final s = v.toStringAsFixed(2);
    return '$cur$s';
  }

  @override
  Widget build(BuildContext context) {
    final cur = quote['currency'] as String? ?? '';
    final bcp = (quote['bcp'] as num?)?.toInt() ?? 0;
    final rate = (quote['rate'] as num?) ?? 0;
    final rateBase = (quote['rate_base'] as num?)?.toInt() ?? 1000;
    final gross = (quote['gross'] as num?) ?? 0;
    final feeEnabled = quote['fee_enabled'] as bool? ?? false;
    final fee = (quote['fee'] as num?) ?? 0;
    final net = (quote['net'] as num?) ?? 0;

    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('You will receive',
              style: TextStyle(
                  color: context.cx.textSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(_money(cur, net),
              style: const TextStyle(
                  fontSize: 26, fontWeight: FontWeight.w900)),
          const SizedBox(height: 12),
          _row(context, 'Rate', '$rateBase BCP = ${_money(cur, rate)}'),
          _row(context, 'Amount', '$bcp BCP'),
          _row(context, 'Gross', _money(cur, gross)),
          _row(context, feeEnabled ? 'Fee' : 'Fee (none)',
              feeEnabled ? '- ${_money(cur, fee)}' : _money(cur, 0)),
          Divider(height: 18, color: context.cx.border),
          _row(context, 'Final amount', _money(cur, net), bold: true),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, String k, String v, {bool bold = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
              child: Text(k,
                  style: TextStyle(
                      color: context.cx.textSecondary,
                      fontWeight: bold ? FontWeight.w800 : FontWeight.w500))),
          Text(v,
              style: TextStyle(
                  fontWeight: bold ? FontWeight.w900 : FontWeight.w700,
                  fontSize: bold ? 15 : 14)),
        ],
      ),
    );
  }
}
