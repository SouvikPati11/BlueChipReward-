import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/ad_gate.dart';
import '../../../core/widgets/banner_ad_bar.dart';
import '../../../core/widgets/common.dart';
import '../../../providers/data_providers.dart';
import '../../../providers/repositories.dart';
import 'package:bluechip_rewards/core/theme/app_palette.dart';

class WatchAdsScreen extends ConsumerStatefulWidget {
  const WatchAdsScreen({super.key});

  @override
  ConsumerState<WatchAdsScreen> createState() => _WatchAdsScreenState();
}

class _WatchAdsScreenState extends ConsumerState<WatchAdsScreen> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // warm the shared rewarded ad
    ref.read(rewardedAdServiceProvider).preload();
  }

  Future<void> _watch() async {
    setState(() => _busy = true);
    try {
      // A completed-ad nonce is mandatory for watch-ads (the reward exists only
      // because an ad was watched). runRewardedGate throws if not completed.
      final nonce = await runRewardedGate(ref, 'watch_ads');
      // Server decides the reward and enforces limits.
      final res = await ref.read(earnRepositoryProvider).rewardAd(nonce);
      ref.invalidate(walletProvider);
      ref.invalidate(transactionsProvider);
      if (mounted) {
        await showRewardDialog(context,
            amount: (res['amount'] as num).toInt(), title: 'Ad reward!');
      }
    } catch (e) {
      if (mounted) showSnack(context, '$e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Watch Ads')),
      bottomNavigationBar: const BannerAdBar(),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            SectionCard(
              gradient: const LinearGradient(
                colors: [AppColors.success, Color(0xFF34D399)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  Container(
                    width: 90,
                    height: 90,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: .18),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.play_circle_fill_rounded,
                        color: Colors.white, size: 50),
                  ),
                  const SizedBox(height: 16),
                  const Text('Watch & Earn',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.w800)),
                  const SizedBox(height: 6),
                  Text('Watch a short video to earn instant BCP.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white.withValues(alpha: .9))),
                ],
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _busy ? null : _watch,
              icon: _busy
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2.2, color: Colors.white))
                  : const Icon(Icons.smart_display_rounded),
              label: Text(_busy ? 'Loading ad…' : 'Watch ad'),
            ),
            const SizedBox(height: 16),
            const _RulesCard(),
          ],
        ),
      ),
    );
  }
}

class _RulesCard extends StatelessWidget {
  const _RulesCard();

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('How it works',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
          const SizedBox(height: 12),
          _rule(context, Icons.verified_user_rounded,
              'Rewards are granted only after a completed ad — verified on the server.'),
          _rule(context, Icons.timelapse_rounded,
              'A short cooldown applies between ads to prevent abuse.'),
          _rule(context, Icons.today_rounded,
              'There is a daily limit on rewarded ads.'),
        ],
      ),
    );
  }

  Widget _rule(BuildContext context, IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: AppColors.primary),
          const SizedBox(width: 10),
          Expanded(
              child: Text(text,
                  style: TextStyle(color: context.cx.textSecondary))),
        ],
      ),
    );
  }
}
