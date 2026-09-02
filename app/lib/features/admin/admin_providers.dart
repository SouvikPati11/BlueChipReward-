import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/wallet_models.dart';
import '../../providers/repositories.dart';

final adminStatsProvider =
    FutureProvider.autoDispose<Map<String, dynamic>>((ref) {
  return ref.watch(adminRepositoryProvider).stats();
});

final adminWithdrawalsProvider =
    FutureProvider.autoDispose<List<Withdrawal>>((ref) {
  return ref.watch(adminRepositoryProvider).pendingWithdrawals();
});

final adminTasksProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
  return ref.watch(adminRepositoryProvider).pendingTasks();
});

final adminSettingsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
  return ref.watch(adminRepositoryProvider).settings();
});

final adminUsersProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, search) {
  return ref.watch(adminRepositoryProvider).users(search: search);
});

final adminAllTasksProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
  return ref.watch(adminRepositoryProvider).allTasks();
});

final adminQuizzesProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
  return ref.watch(adminRepositoryProvider).quizzes();
});

final adminQuizQuestionsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, quizId) {
  return ref.watch(adminRepositoryProvider).quizQuestions(quizId);
});

final adminPaymentMethodsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
  return ref.watch(adminRepositoryProvider).allPaymentMethods();
});

final adminAuditProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
  return ref.watch(adminRepositoryProvider).auditLogs();
});

/// Analytics date range for the dashboard (server-side filtered).
class AnalyticsRange {
  final DateTime? from;
  final DateTime? to;
  final String label;
  const AnalyticsRange(this.label, this.from, this.to);
}

final adminAnalyticsRangeProvider =
    StateProvider<AnalyticsRange>((ref) => allTimeRange());

AnalyticsRange allTimeRange() => const AnalyticsRange('All time', null, null);

final adminAnalyticsProvider =
    FutureProvider.autoDispose<Map<String, dynamic>>((ref) {
  final r = ref.watch(adminAnalyticsRangeProvider);
  return ref.watch(adminRepositoryProvider).analytics(from: r.from, to: r.to);
});

final adminWithdrawalsDetailedProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, status) {
  return ref.watch(adminRepositoryProvider).withdrawalsDetailed(status);
});

final adminReferralReviewsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, status) {
  return ref.watch(adminRepositoryProvider).referralReviews(status);
});

final adminInviteClaimsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, status) {
  return ref.watch(adminRepositoryProvider).inviteClaims(status);
});

final adminTaskSubmissionsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, status) {
  return ref.watch(adminRepositoryProvider).taskSubmissions(status);
});

final adminInviteMilestonesProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
  return ref.watch(adminRepositoryProvider).inviteMilestones();
});

final adminAppLinksProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
  return ref.watch(adminRepositoryProvider).appLinks();
});

final adminContestsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
  return ref.watch(adminRepositoryProvider).contests();
});

final adminContestClaimsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, status) {
  return ref.watch(adminRepositoryProvider).contestClaims(status);
});
