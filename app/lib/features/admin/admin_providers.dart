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
