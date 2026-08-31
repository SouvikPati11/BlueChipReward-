import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/config/constants.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/formatters.dart';
import '../../../models/profile.dart';

/// Premium balance card shown at the top of Home and Wallet.
class BalanceHero extends StatelessWidget {
  final Profile? profile;
  final Wallet wallet;
  final bool showActions;
  const BalanceHero({
    super.key,
    required this.wallet,
    this.profile,
    this.showActions = true,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        gradient: AppColors.heroGradient,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withOpacity(.28),
            blurRadius: 24,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Your ${K.currency} balance',
                  style: TextStyle(color: Colors.white.withOpacity(.85))),
              const Spacer(),
              const Icon(Icons.verified_rounded,
                  color: Colors.white, size: 18),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Icon(Icons.monetization_on_rounded,
                  color: AppColors.gold, size: 34),
              const SizedBox(width: 8),
              Text(Fmt.points(wallet.balance),
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 40,
                      fontWeight: FontWeight.w900,
                      height: 1)),
              const SizedBox(width: 6),
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(K.currency,
                    style: TextStyle(
                        color: Colors.white.withOpacity(.8),
                        fontWeight: FontWeight.w700)),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              _mini('Earned', wallet.totalEarned),
              Container(
                  width: 1,
                  height: 30,
                  color: Colors.white.withOpacity(.2)),
              _mini('Pending', wallet.pendingWithdrawal),
              Container(
                  width: 1,
                  height: 30,
                  color: Colors.white.withOpacity(.2)),
              _mini('Withdrawn', wallet.totalWithdrawn),
            ],
          ),
          if (showActions) ...[
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: _action(context, Icons.bolt_rounded, 'Earn', '/earn'),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _action(context, Icons.account_balance_wallet_rounded,
                      'Withdraw', '/withdraw'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _mini(String label, int value) {
    return Expanded(
      child: Column(
        children: [
          Text(Fmt.points(value),
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w800)),
          const SizedBox(height: 2),
          Text(label,
              style: TextStyle(
                  color: Colors.white.withOpacity(.75), fontSize: 12)),
        ],
      ),
    );
  }

  Widget _action(
      BuildContext context, IconData icon, String label, String route) {
    return Material(
      color: Colors.white.withOpacity(.16),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => context.push(route),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: Colors.white, size: 20),
              const SizedBox(width: 8),
              Text(label,
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w700)),
            ],
          ),
        ),
      ),
    );
  }
}
