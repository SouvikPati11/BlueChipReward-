import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/config/constants.dart';
import '../../../core/theme/app_colors.dart';

/// Shared premium header + scrollable body for auth screens.
class AuthScaffold extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget child;
  const AuthScaffold({
    super.key,
    required this.title,
    required this.subtitle,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    // Light status-bar icons over the blue hero for readability.
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light.copyWith(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
      ),
      child: Scaffold(
        body: SafeArea(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 26),
                  decoration: const BoxDecoration(
                    gradient: AppColors.heroGradient,
                    borderRadius: BorderRadius.only(
                      bottomLeft: Radius.circular(28),
                      bottomRight: Radius.circular(28),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        const _BrandMark(),
                        const SizedBox(width: 10),
                        const Text(K.appName,
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 17,
                                fontWeight: FontWeight.w800)),
                      ]),
                      const SizedBox(height: 22),
                      Text(title,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 25,
                              fontWeight: FontWeight.w900)),
                      const SizedBox(height: 6),
                      Text(subtitle,
                          style: TextStyle(
                              color: Colors.white.withValues(alpha: .85),
                              fontSize: 14.5)),
                      const SizedBox(height: 16),
                      const _BenefitsRow(),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
                  child: child,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The app's brand mark. Shows the official logo (assets/branding/logo.png)
/// when present, gracefully falling back to a placeholder so the build never
/// depends on the asset existing yet.
class _BrandMark extends StatelessWidget {
  const _BrandMark();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .16),
        borderRadius: BorderRadius.circular(14),
      ),
      clipBehavior: Clip.antiAlias,
      child: Image.asset(
        'assets/branding/logo.png',
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) =>
            const Icon(Icons.diamond_rounded, color: Colors.white),
      ),
    );
  }
}

class _BenefitsRow extends StatelessWidget {
  const _BenefitsRow();

  @override
  Widget build(BuildContext context) {
    const items = [
      (Icons.bolt_rounded, 'Earn BCP'),
      (Icons.checklist_rounded, 'Do activities'),
      (Icons.card_giftcard_rounded, 'Get rewarded'),
    ];
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Row(
        children: [
          for (final it in items)
            Padding(
              padding: const EdgeInsets.only(right: 14),
              child: Row(children: [
                Icon(it.$1,
                    color: Colors.white.withValues(alpha: .95), size: 16),
                const SizedBox(width: 5),
                Text(it.$2,
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: .95),
                        fontSize: 12,
                        fontWeight: FontWeight.w600)),
              ]),
            ),
        ],
      ),
    );
  }
}
