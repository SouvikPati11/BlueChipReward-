import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/earn_models.dart';
import '../models/profile.dart';
import '../models/wallet_models.dart';
import 'repositories.dart';

/// Profile + wallet + transactions. These auto-dispose and are re-fetched by
/// invalidating them after any earning action so balances stay live.

final profileProvider = FutureProvider.autoDispose<Profile>((ref) {
  return ref.watch(userRepositoryProvider).fetchProfile();
});

final walletProvider = FutureProvider.autoDispose<Wallet>((ref) {
  return ref.watch(userRepositoryProvider).fetchWallet();
});

final transactionsProvider =
    FutureProvider.autoDispose<List<WalletTransaction>>((ref) {
  return ref.watch(userRepositoryProvider).fetchTransactions();
});

final notificationsProvider =
    FutureProvider.autoDispose<List<AppNotification>>((ref) {
  return ref.watch(userRepositoryProvider).fetchNotifications();
});

/// Admin-configured links shown in Settings.
final appLinksProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
  return ref.watch(userRepositoryProvider).appLinks();
});

final dailyStatusProvider = FutureProvider.autoDispose<DailyStatus>((ref) {
  return ref.watch(earnRepositoryProvider).dailyStatus();
});

final miningStatusProvider = FutureProvider.autoDispose<MiningStatus>((ref) {
  return ref.watch(earnRepositoryProvider).miningStatus();
});

final tasksProvider = FutureProvider.autoDispose<List<TaskItem>>((ref) {
  return ref.watch(earnRepositoryProvider).fetchTasks();
});

final inviteMilestonesProvider =
    FutureProvider.autoDispose<InviteMilestonesOverview>((ref) {
  return ref.watch(earnRepositoryProvider).inviteMilestones();
});

final quizProvider = FutureProvider.autoDispose<DailyQuiz>((ref) {
  return ref.watch(earnRepositoryProvider).quizToday();
});

final paymentMethodsProvider =
    FutureProvider.autoDispose<List<PaymentMethod>>((ref) {
  return ref.watch(walletRepositoryProvider).fetchPaymentMethods();
});

final withdrawalsProvider =
    FutureProvider.autoDispose<List<Withdrawal>>((ref) {
  return ref.watch(walletRepositoryProvider).fetchWithdrawals();
});

final referralStatsProvider =
    FutureProvider.autoDispose<ReferralStats>((ref) async {
  final profile = await ref.watch(profileProvider.future);
  return ref
      .watch(walletRepositoryProvider)
      .fetchReferralStats(profile.referralCode);
});
