import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_colors.dart';
import '../../core/widgets/common.dart';
import 'earn_methods.dart';
import 'package:bluechip_rewards/core/theme/app_palette.dart';

class EarnHubScreen extends StatelessWidget {
  const EarnHubScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Earn BCP')),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            Text('Choose how you want to earn',
                style: TextStyle(color: context.cx.textSecondary)),
            const SizedBox(height: 16),
            for (final m in earnMethods) ...[
              _EarnRow(method: m),
              const SizedBox(height: 12),
            ],
          ],
        ),
      ),
    );
  }
}

class _EarnRow extends StatelessWidget {
  final EarnMethod method;
  const _EarnRow({required this.method});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () => context.push(method.route),
      child: SectionCard(
        child: Row(
          children: [
            Container(
              width: 54,
              height: 54,
              decoration: BoxDecoration(
                color: method.color.withOpacity(.12),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(method.icon, color: method.color, size: 28),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(method.title,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 2),
                  Text(method.subtitle,
                      style: TextStyle(color: context.cx.textSecondary)),
                ],
              ),
            ),
            Icon(Icons.arrow_forward_ios_rounded,
                size: 16, color: context.cx.textSecondary),
          ],
        ),
      ),
    );
  }
}
