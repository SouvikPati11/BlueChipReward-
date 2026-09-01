import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import 'package:bluechip_rewards/core/theme/app_palette.dart';

/// Small shared building blocks.

class SectionCard extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final Gradient? gradient;
  final Color? color;
  const SectionCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.gradient,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: gradient == null ? (color ?? context.cx.surface) : null,
        gradient: gradient,
        borderRadius: BorderRadius.circular(20),
        border: gradient == null
            ? Border.all(color: context.cx.border)
            : null,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .03),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      padding: padding,
      child: child,
    );
  }
}

class Pill extends StatelessWidget {
  final String text;
  final Color color;
  final IconData? icon;
  const Pill(this.text, {super.key, this.color = AppColors.primary, this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 4),
          ],
          Text(text,
              style: TextStyle(
                  color: color, fontSize: 12, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

class BcpAmount extends StatelessWidget {
  final int amount;
  final double size;
  final Color? color;
  final bool showSign;
  const BcpAmount(this.amount,
      {super.key, this.size = 16, this.color, this.showSign = false});

  @override
  Widget build(BuildContext context) {
    final sign = showSign ? (amount >= 0 ? '+' : '') : '';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.monetization_on_rounded,
            size: size + 2, color: color ?? AppColors.gold),
        const SizedBox(width: 4),
        Text('$sign$amount',
            style: TextStyle(
                fontSize: size,
                fontWeight: FontWeight.w800,
                color: color ?? context.cx.textPrimary)),
      ],
    );
  }
}

/// Toast-style feedback.
void showSnack(BuildContext context, String message, {bool error = false}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: error ? AppColors.danger : context.cx.textPrimary,
      duration: const Duration(seconds: 3),
    ));
}

/// A celebratory reward dialog.
Future<void> showRewardDialog(BuildContext context,
    {required int amount, String title = 'Reward earned!'}) {
  return showDialog(
    context: context,
    builder: (_) => Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 84,
              height: 84,
              decoration: const BoxDecoration(
                  gradient: AppColors.goldGradient, shape: BoxShape.circle),
              child: const Icon(Icons.emoji_events_rounded,
                  color: Colors.white, size: 44),
            ),
            const SizedBox(height: 18),
            Text(title,
                style: const TextStyle(
                    fontSize: 20, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            Text('+$amount BCP',
                style: const TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.w900,
                    color: AppColors.gold)),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Awesome!'),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
