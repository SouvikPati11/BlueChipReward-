import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/repositories.dart';
import '../error/failure.dart';
import 'rewarded_ad_service.dart';

/// One app-wide rewarded-ad loader so ads can be preloaded and reused.
final rewardedAdServiceProvider = Provider<RewardedAdService>((ref) {
  final service = RewardedAdService();
  ref.onDispose(service.dispose);
  return service;
});

/// Runs the full rewarded-ad gate for [placement]:
///   1. opens a server-side ad event (nonce),
///   2. shows the rewarded ad, reporting impression/reward to the server,
///   3. returns the nonce that authorises the gated reward.
///
/// Throws an [AppFailure] if no ad could be shown or the user didn't complete
/// it — the caller must NOT credit in that case (rewards require a completed ad).
Future<String> runRewardedGate(WidgetRef ref, String placement) async {
  final repo = ref.read(earnRepositoryProvider);
  final ads = ref.read(rewardedAdServiceProvider);

  final nonce = await repo.adBegin(placement);
  var impressed = false;
  var earned = false;

  final shown = await ads.show(
    onImpression: () => impressed = true,
    onEarned: () => earned = true,
  );

  if (impressed) {
    try {
      await repo.adMark(nonce, 'impressed');
    } catch (_) {/* best-effort funnel accounting */}
  }

  if (!shown || !earned) {
    throw AppFailure(
      'AD',
      impressed
          ? 'Watch the full ad to earn your reward.'
          : 'No ad available right now. Please try again in a moment.',
    );
  }

  await repo.adMark(nonce, 'rewarded');
  return nonce;
}
