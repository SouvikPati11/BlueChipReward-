import '../utils/rewarded_ad_service.dart';

/// The ad networks an admin can select per placement.
enum AdNetwork { admob, applovin, unity }

AdNetwork adNetworkFromString(String? s) {
  switch ((s ?? 'admob').toLowerCase()) {
    case 'applovin':
      return AdNetwork.applovin;
    case 'unity':
      return AdNetwork.unity;
    default:
      return AdNetwork.admob;
  }
}

/// Routes a rewarded-ad request to the network the admin selected for the
/// placement. AdMob is always available (public test units). AppLovin and Unity
/// are only usable once their account keys are supplied and their SDKs have
/// initialised (see main.dart / AppConfig): [applovinReady] / [unityReady].
///
/// When a placement is configured for a network that is not ready, the request
/// transparently falls back to AdMob so the reward flow never breaks — and
/// because reward verification is server-side (the ad_events funnel nonce), the
/// network that actually served the ad does not change what gets credited.
class RewardedAdManager {
  final RewardedAdService _admob = RewardedAdService();

  /// Set true after the corresponding SDK initialises with a valid key.
  static bool applovinReady = false;
  static bool unityReady = false;

  bool _isReady(AdNetwork n) => n == AdNetwork.admob; // only AdMob serves today

  /// The network that will actually serve, after applying readiness fallback.
  AdNetwork effectiveNetwork(AdNetwork requested) =>
      _isReady(requested) ? requested : AdNetwork.admob;

  Future<void> preload(
      [AdNetwork network = AdNetwork.admob, String? unitId]) {
    switch (effectiveNetwork(network)) {
      case AdNetwork.admob:
      case AdNetwork.applovin:
      case AdNetwork.unity:
        return _admob.preload(unitId: unitId);
    }
  }

  bool get isReady => _admob.isReady;

  /// Shows a rewarded ad on the effective network. [unitId] is the admin-
  /// configured AdMob unit from ads_config (empty in test mode → the service
  /// falls back to the build-time/test unit). Returns true if the user earned
  /// the reward (the server still authorises the actual BCP).
  Future<bool> show(
    AdNetwork network, {
    String? unitId,
    void Function()? onImpression,
    void Function()? onEarned,
  }) {
    switch (effectiveNetwork(network)) {
      case AdNetwork.admob:
      case AdNetwork.applovin:
      case AdNetwork.unity:
        // AppLovin/Unity serving is wired once their keys are provided; until
        // then the effective network is AdMob (see effectiveNetwork).
        return _admob.show(
            unitId: unitId, onImpression: onImpression, onEarned: onEarned);
    }
  }

  void dispose() => _admob.dispose();
}
