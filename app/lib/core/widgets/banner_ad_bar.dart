import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import '../../providers/data_providers.dart';
import '../config/app_config.dart';
import '../theme/app_palette.dart';

/// A theme-aware anchored adaptive banner for the bottom of earning screens.
///
/// Placement-aware: it only loads/renders when the admin has banners enabled
/// globally AND for this [placement]. Loads gracefully — shows nothing until an
/// ad is ready and collapses to zero height if disabled or on failure, so it
/// never covers content or leaves a blank gap. Meant to be used as a Scaffold
/// `bottomNavigationBar` so it always sits pinned at the bottom.
class BannerAdBar extends ConsumerStatefulWidget {
  final String placement;
  const BannerAdBar({super.key, required this.placement});

  @override
  ConsumerState<BannerAdBar> createState() => _BannerAdBarState();
}

class _BannerAdBarState extends ConsumerState<BannerAdBar> {
  BannerAd? _ad;
  bool _loaded = false;
  bool _started = false;

  String get _unitId => AppConfig.admobBannerAdUnit.isNotEmpty
      ? AppConfig.admobBannerAdUnit
      // Google's official test banner unit — safe default.
      : 'ca-app-pub-3940256099942544/6300978111';

  Future<void> _load() async {
    if (_started) return;
    _started = true;
    try {
      final width = MediaQuery.of(context).size.width.truncate();
      final size = await AdSize.getAnchoredAdaptiveBannerAdSize(
          Orientation.portrait, width);
      if (size == null) return;
      final ad = BannerAd(
        adUnitId: _unitId,
        size: size,
        request: const AdRequest(),
        listener: BannerAdListener(
          onAdLoaded: (_) {
            if (mounted) setState(() => _loaded = true);
          },
          onAdFailedToLoad: (ad, err) {
            ad.dispose();
            if (mounted) setState(() => _ad = null);
          },
        ),
      );
      _ad = ad;
      await ad.load();
    } catch (_) {
      _ad = null; // ads are non-essential; never surface a failure
    }
  }

  @override
  void dispose() {
    _ad?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = ref.watch(adsConfigProvider).maybeWhen(
          data: (c) => c.bannerFor(widget.placement),
          orElse: () => true, // optimistic until config loads
        );
    if (!enabled) return const SizedBox.shrink();

    // Kick off the load once we know banners are enabled.
    if (!_started) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }

    final ad = _ad;
    if (ad == null || !_loaded) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      alignment: Alignment.center,
      color: context.cx.surface,
      child: SizedBox(
        width: ad.size.width.toDouble(),
        height: ad.size.height.toDouble(),
        child: AdWidget(ad: ad),
      ),
    );
  }
}
