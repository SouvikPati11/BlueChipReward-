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
