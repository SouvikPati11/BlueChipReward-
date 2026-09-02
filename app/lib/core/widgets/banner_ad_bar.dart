import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import '../../providers/data_providers.dart';
import '../config/app_config.dart';
import '../theme/app_palette.dart';

/// A theme-aware anchored **adaptive banner**, pinned to the very bottom of a
/// screen. It is designed to be used ONLY as a Scaffold `bottomNavigationBar`
/// so it can never float in the middle of the screen or cover content.
///
/// Hard guarantees (see the layout bug fix):
///  * The banner occupies its own fixed-height strip at the bottom — never the
///    full screen height, never `Expanded`/`match-parent`.
///  * Its height is exactly the loaded ad's height, clamped to [_maxBannerH]
///    so a bad/oversized size can never blow up the layout.
///  * Until an ad is actually loaded (or if banners are disabled / the ad fails
///    to load) it collapses to zero height — no giant blank reserved area.
///  * It uses only [BannerAd] (banner inventory). Rewarded ads used by Watch
///    Ads / Scratch / Mining Claim go through a completely separate service and
///    never touch this widget.
class BannerAdBar extends ConsumerStatefulWidget {
  final String placement;
  const BannerAdBar({super.key, required this.placement});

  @override
  ConsumerState<BannerAdBar> createState() => _BannerAdBarState();
}

// A standard anchored adaptive banner is ~50–90dp tall; this is a safety cap so
// a misreported size can never occupy a large area.
const double _maxBannerH = 90;

class _BannerAdBarState extends ConsumerState<BannerAdBar> {
  BannerAd? _ad;
  bool _loaded = false;
  bool _started = false;

  String get _unitId => AppConfig.admobBannerAdUnit.isNotEmpty
      ? AppConfig.admobBannerAdUnit
      // Google's official test banner unit — safe default.
      : 'ca-app-pub-3940256099942544/6300978111';

  Future<void> _load() async {
    if (_started || !mounted) return;
    _started = true;
    try {
      final width = MediaQuery.of(context).size.width.truncate();
      final size = await AdSize.getAnchoredAdaptiveBannerAdSize(
          Orientation.portrait, width);
      if (size == null || !mounted) return;
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
            if (mounted) {
              setState(() {
                _ad = null;
                _loaded = false;
              });
            }
          },
        ),
      );
      _ad = ad;
      await ad.load();
    } catch (_) {
      // Ads are non-essential; a failure must never surface or reserve space.
      if (mounted) {
        setState(() {
          _ad = null;
          _loaded = false;
        });
      }
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

    // Kick off the load once we know banners are enabled for this placement.
    if (!_started) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }

    final ad = _ad;
    // Nothing loaded yet / failed → occupy zero space. Never reserve a blank
    // area and never render an unbounded/loading container.
    if (ad == null || !_loaded) return const SizedBox.shrink();

    // Clamp to a safe height so the banner strip can never grow large.
    final h = math.min(ad.size.height.toDouble(), _maxBannerH);

    return SafeArea(
      top: false,
      child: Container(
        width: double.infinity,
        height: h, // exact, bounded height — never full-screen
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: context.cx.surface,
          border: Border(
            top: BorderSide(color: context.cx.border, width: .5),
          ),
        ),
        child: ClipRect(
          child: SizedBox(
            width: ad.size.width.toDouble(),
            height: h,
            child: AdWidget(ad: ad),
          ),
        ),
      ),
    );
  }
}
