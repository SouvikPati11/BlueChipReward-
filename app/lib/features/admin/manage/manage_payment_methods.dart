import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:bluechip_rewards/core/theme/app_colors.dart';
import 'package:bluechip_rewards/core/theme/app_palette.dart';
import '../../../core/widgets/common.dart';
import '../../../core/widgets/state_views.dart';
import '../../../providers/repositories.dart';
import '../admin_providers.dart';

class ManagePaymentMethodsScreen extends ConsumerWidget {
  const ManagePaymentMethodsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(adminPaymentMethodsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Payment Methods')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(context, ref, null),
        icon: const Icon(Icons.add_rounded),
        label: const Text('New method'),
      ),
      body: async.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(
            error: e, onRetry: () => ref.invalidate(adminPaymentMethodsProvider)),
        data: (methods) {
          if (methods.isEmpty) {
            return const EmptyView(
                icon: Icons.account_balance_rounded, title: 'No payment methods');
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 90),
            itemCount: methods.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (_, i) {
              final m = methods[i];
              final active = m['active'] == true;
              final fields = (m['fields'] as List?)?.length ?? 0;
              return SectionCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text('${m['name']}  (${m['key']})',
                              style: const TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.w800)),
                        ),
                        Pill(active ? 'ACTIVE' : 'HIDDEN',
                            color: active
                                ? AppColors.success
                                : AppColors.textSecondary),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                        'Min ${m['min_amount']} BCP • $fields field(s)\n${m['rate_base'] ?? 1000} BCP = ${m['currency'] ?? '₹'}${m['rate'] ?? 0}',
                        style: TextStyle(color: context.cx.textSecondary)),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        const Spacer(),
                        TextButton.icon(
                          onPressed: () => _edit(context, ref, m),
                          icon: const Icon(Icons.edit_rounded, size: 18),
                          label: const Text('Edit'),
                        ),
                        TextButton.icon(
                          onPressed: () async {
                            try {
                              await ref
                                  .read(adminRepositoryProvider)
                                  .deletePaymentMethod(m['id'] as String);
                              ref.invalidate(adminPaymentMethodsProvider);
                            } catch (e) {
                              if (context.mounted) {
                                showSnack(context, '$e', error: true);
                              }
                            }
                          },
                          style: TextButton.styleFrom(
                              foregroundColor: AppColors.danger),
                          icon: const Icon(Icons.delete_outline_rounded, size: 18),
                          label: const Text('Delete'),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _edit(
      BuildContext context, WidgetRef ref, Map<String, dynamic>? m) async {
    final key = TextEditingController(text: m?['key'] ?? '');
    final name = TextEditingController(text: m?['name'] ?? '');
    final minAmount =
        TextEditingController(text: (m?['min_amount'] ?? 1000).toString());
    final currency = TextEditingController(text: m?['currency'] ?? '₹');
    final rate = TextEditingController(text: (m?['rate'] ?? 0).toString());
    final rateBase =
        TextEditingController(text: (m?['rate_base'] ?? 1000).toString());
    final fields = TextEditingController(
        text: const JsonEncoder.withIndent('  ')
            .convert(m?['fields'] ?? [
              {'key': 'account', 'label': 'Account', 'type': 'text'}
            ]));
    bool active = m?['active'] ?? true;
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => Padding(
          padding: EdgeInsets.only(
              left: 16,
              right: 16,
              top: 16,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 16),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(m == null ? 'New payment method' : 'Edit payment method',
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w800)),
                const SizedBox(height: 12),
                TextField(controller: key, decoration: const InputDecoration(labelText: 'Key (e.g. upi)')),
                const SizedBox(height: 10),
                TextField(controller: name, decoration: const InputDecoration(labelText: 'Name')),
                const SizedBox(height: 10),
                TextField(controller: minAmount, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Minimum (BCP)')),
                const SizedBox(height: 10),
                // Conversion rate: `rate` payout-currency units per `rate_base` BCP.
                Row(
                  children: [
                    SizedBox(
                      width: 80,
                      child: TextField(
                          controller: currency,
                          decoration:
                              const InputDecoration(labelText: 'Currency')),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                          controller: rateBase,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                              labelText: 'BCP', helperText: 'per…')),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                          controller: rate,
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          decoration: const InputDecoration(
                              labelText: 'Amount', helperText: '= this')),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: fields,
                  maxLines: 6,
                  decoration: const InputDecoration(
                    labelText: 'Fields (JSON array)',
                    helperText: 'e.g. [{"key":"upi_id","label":"UPI ID","type":"text"}]',
                  ),
                ),
                SwitchListTile(
                  value: active,
                  onChanged: (v) => setState(() => active = v),
                  title: const Text('Active'),
                  contentPadding: EdgeInsets.zero,
                ),
                const SizedBox(height: 8),
                ElevatedButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Save'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (ok != true) return;
    dynamic parsedFields;
    try {
      parsedFields = jsonDecode(fields.text.trim());
    } catch (_) {
      if (context.mounted) showSnack(context, 'Fields must be valid JSON', error: true);
      return;
    }
    try {
      await ref.read(adminRepositoryProvider).savePaymentMethod({
        'id': m?['id'],
        'key': key.text.trim(),
        'name': name.text.trim(),
        'fields': parsedFields,
        'min_amount': int.tryParse(minAmount.text.trim()) ?? 0,
        'active': active,
        'position': m?['position'] ?? 0,
        'currency': currency.text.trim().isEmpty ? '₹' : currency.text.trim(),
        'rate': num.tryParse(rate.text.trim()) ?? 0,
        'rate_base': int.tryParse(rateBase.text.trim()) ?? 1000,
      });
      ref.invalidate(adminPaymentMethodsProvider);
    } catch (e) {
      if (context.mounted) showSnack(context, '$e', error: true);
    }
  }
}
