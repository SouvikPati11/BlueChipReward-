import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import '../config/app_config.dart';
import '../theme/app_palette.dart';

/// A theme-aware anchored adaptive banner for the bottom of earning screens.
/// Loads gracefully: shows nothing until an ad is ready, and quietly collapses
/// if loading fails, so it never breaks the layout or blocks the screen.
class BannerAdBar extends StatefulWidget {
  const BannerAdBar({super.key});

  @override
  State<BannerAdBar> createState() => _BannerAdBarState();
}

class _BannerAdBarState extends State<BannerAdBar> {
  BannerAd? _ad;
  bool _loaded = false;

  String get _unitId => AppConfig.admobBannerAdUnit.isNotEmpty
      ? AppConfig.admobBannerAdUnit
      // Google's official test banner unit — safe default.
      : 'ca-app-pub-3940256099942544/6300978111';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_ad == null) _load();
  }

  Future<void> _load() async {
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
      // Ads are non-essential; never surface a failure to the user.
      _ad = null;
    }
  }

  @override
  void dispose() {
    _ad?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
