import 'dart:async';

import 'package:google_mobile_ads/google_mobile_ads.dart';

import '../config/app_config.dart';

/// Loads and shows AdMob rewarded ads. On a valid reward callback it resolves
/// so the caller can hit the server RPC. The server — not this callback — is
/// the source of truth for the BCP granted.
class RewardedAdService {
  RewardedAd? _ad;
  bool _loading = false;

  String get _unitId => AppConfig.admobRewardedAdUnit.isNotEmpty
      ? AppConfig.admobRewardedAdUnit
      // Google's official test rewarded unit — safe default.
      : 'ca-app-pub-3940256099942544/5224354917';

  Future<void> preload() async {
    if (_ad != null || _loading) return;
    _loading = true;
    final completer = Completer<void>();
    RewardedAd.load(
      adUnitId: _unitId,
      request: const AdRequest(),
      rewardedAdLoadCallback: RewardedAdLoadCallback(
        onAdLoaded: (ad) {
          _ad = ad;
          _loading = false;
          if (!completer.isCompleted) completer.complete();
        },
        onAdFailedToLoad: (err) {
          _ad = null;
          _loading = false;
          if (!completer.isCompleted) completer.complete();
        },
      ),
    );
    return completer.future;
  }

  /// True if a rewarded ad is loaded and ready to show right now.
  bool get isReady => _ad != null;

  /// Shows the ad. Returns true if the user earned the reward. The reward is
  /// authorised server-side (reward_ad / gated RPCs); this only reports the
  /// AdMob lifecycle. [onImpression] fires when the ad is shown, [onEarned]
  /// when AdMob reports the reward callback.
  Future<bool> show({void Function()? onImpression, void Function()? onEarned}) async {
    if (_ad == null) await preload();
    final ad = _ad;
    if (ad == null) return false;

    final completer = Completer<bool>();
    var earned = false;

    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdShowedFullScreenContent: (ad) {
        onImpression?.call();
      },
      onAdDismissedFullScreenContent: (ad) {
        ad.dispose();
        _ad = null;
        preload(); // warm the next one
        if (!completer.isCompleted) completer.complete(earned);
      },
      onAdFailedToShowFullScreenContent: (ad, err) {
        ad.dispose();
        _ad = null;
        if (!completer.isCompleted) completer.complete(false);
      },
    );

    ad.show(onUserEarnedReward: (ad, reward) {
      earned = true;
      onEarned?.call();
    });

    return completer.future;
  }

  void dispose() {
    _ad?.dispose();
    _ad = null;
  }
}
