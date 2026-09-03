import '../../core/error/failure.dart';
import '../../core/supabase/supabase_client.dart';
import '../../models/wallet_models.dart';

/// Outcome of sending a custom notification: the in-app fan-out count plus the
/// real push-delivery status from the FCM edge function.
class SendResult {
  final int recipients; // in-app recipients (broadcast counts active users)
  final bool pushConfigured; // FCM service account present on the server
  final bool pushError; // push call failed / function unavailable
  final int pushSent;
  final int pushFailed;
  final int pushCleaned;
  const SendResult({
    required this.recipients,
    this.pushConfigured = false,
    this.pushError = false,
    this.pushSent = 0,
    this.pushFailed = 0,
    this.pushCleaned = 0,
  });
}

/// Admin data access. Every mutating call maps to a server RPC that re-checks
/// the admin role — the client role flag is only used to reveal the UI.
class AdminRepository {
  Future<Map<String, dynamic>> stats() async {
    try {
      final res = await Db.client.rpc('admin_stats');
      return (res as Map).cast<String, dynamic>();
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  Future<List<Withdrawal>> pendingWithdrawals() async {
    try {
      final rows = await Db.client
          .from('withdrawals')
          .select()
          .inFilter('status', ['pending', 'approved'])
          .order('created_at');
      return (rows as List)
          .map((e) => Withdrawal.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  Future<void> processWithdrawal(String id, String status,
      {String? notes}) async {
    try {
      await Db.client.rpc('admin_process_withdrawal',
          params: {'p_id': id, 'p_status': status, 'p_notes': notes});
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  Future<List<Map<String, dynamic>>> pendingTasks() async {
    try {
      final rows = await Db.client
          .from('task_completions')
          .select('id, user_id, proof, created_at, tasks(title, reward)')
          .eq('state', 'pending')
          .order('created_at');
      return (rows as List).map((e) => (e as Map).cast<String, dynamic>()).toList();
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  Future<List<Map<String, dynamic>>> taskSubmissions(String status) async {
    try {
      final res = await Db.client
          .rpc('admin_task_submissions', params: {'p_status': status});
      return (res as List).map((e) => (e as Map).cast<String, dynamic>()).toList();
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  Future<void> reviewTask(String completionId, bool approve,
      {String? notes}) async {
    try {
      await Db.client.rpc('admin_review_task', params: {
        'p_completion_id': completionId,
        'p_approve': approve,
        'p_notes': notes,
      });
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  Future<List<Map<String, dynamic>>> settings() async {
    try {
      final rows =
          await Db.client.from('app_settings').select().order('key');
      return (rows as List).map((e) => (e as Map).cast<String, dynamic>()).toList();
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  Future<void> setSetting(String key, dynamic value, {String? desc}) async {
    try {
      await Db.client.rpc('admin_set_setting',
          params: {'p_key': key, 'p_value': value, 'p_desc': desc});
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  Future<void> broadcast(String title, String body) async {
    try {
      await Db.client
          .rpc('admin_broadcast', params: {'p_title': title, 'p_body': body});
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  /// §29/§30 — send a custom notification now. [target] is 'all' or 'specific';
  /// [userIds] is required when target == 'specific'.
  ///
  /// Two real deliveries happen: (1) the RPC writes the in-app feed + history
  /// (always), then (2) the `push` edge function delivers a real FCM push to
  /// registered devices. Push is best-effort — if FCM is not configured or the
  /// function is unavailable, the in-app notification still succeeded, and the
  /// returned [SendResult.pushConfigured] reflects that so the UI can say so.
  Future<SendResult> sendNotification(String title, String body,
      {String target = 'all', List<String>? userIds}) async {
    // 1. In-app + history (source of truth). Failure here is a real error.
    late final Map<String, dynamic> rpc;
    try {
      final res = await Db.client.rpc('admin_send_notification', params: {
        'p_title': title,
        'p_body': body,
        'p_target': target,
        'p_user_ids': userIds,
      });
      rpc = (res is Map) ? res.cast<String, dynamic>() : <String, dynamic>{};
    } catch (e) {
      throw AppFailure.from(e);
    }
    final recipients = (rpc['recipients'] as num?)?.toInt() ?? 0;
    final id = rpc['id']?.toString();

    // 2. Real push delivery (best-effort).
    try {
      final res = await Db.client.functions.invoke('push', body: {
        'title': title,
        'body': body,
        'route': '/notifications',
        'target': target,
        'user_ids': userIds,
        'id': id,
      });
      final data = res.data;
      final map = (data is Map) ? data.cast<String, dynamic>() : const {};
      return SendResult(
        recipients: recipients,
        pushConfigured: map['configured'] == true,
        pushSent: (map['sent'] as num?)?.toInt() ?? 0,
        pushFailed: (map['failed'] as num?)?.toInt() ?? 0,
        pushCleaned: (map['cleaned'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      // Push unavailable (function not deployed, network, etc.) — in-app is done.
      return SendResult(recipients: recipients, pushError: true);
    }
  }

  Future<List<Map<String, dynamic>>> notificationHistory() async {
    try {
      final res = await Db.client.rpc('admin_notification_history');
      return (res as List).map((e) => (e as Map).cast<String, dynamic>()).toList();
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  Future<List<Map<String, dynamic>>> userOptions({String? search}) async {
    try {
      final res = await Db.client
          .rpc('admin_user_options', params: {'p_search': search});
      return (res as List).map((e) => (e as Map).cast<String, dynamic>()).toList();
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  // ---- Scratch Card rules --------------------------------------------------
  Future<List<Map<String, dynamic>>> scratchRules() async {
    try {
      final res = await Db.client.rpc('admin_scratch_rules');
      return (res as List).map((e) => (e as Map).cast<String, dynamic>()).toList();
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  Future<void> saveScratchRule(Map<String, dynamic> r) async {
    try {
      // Scratch always uses exactly ONE rewarded ad and no artificial delay —
      // the admin does not configure these. The server also forces 1 / 0.
      await Db.client.rpc('admin_save_scratch_rule', params: {
        'p_id': r['id'],
        'p_from': r['from_card'],
        'p_to': r['to_card'],
        'p_min': r['min_reward'],
        'p_max': r['max_reward'],
        'p_ads': 1,
        'p_search_delay': 0,
        'p_cooldown': r['cooldown_seconds'],
        'p_active': r['active'],
        'p_wait_after': r['wait_after_seconds'],
        'p_daily_limit': r['daily_limit'],
      });
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  Future<void> deleteScratchRule(String id) async {
    try {
      await Db.client.rpc('admin_delete_scratch_rule', params: {'p_id': id});
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  // ---- Watch Ads rules -----------------------------------------------------
  Future<List<Map<String, dynamic>>> watchAdRules() async {
    try {
      final res = await Db.client.rpc('admin_watch_ad_rules');
      return (res as List).map((e) => (e as Map).cast<String, dynamic>()).toList();
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  Future<void> saveWatchAdRule(Map<String, dynamic> r) async {
    try {
      await Db.client.rpc('admin_save_watch_ad_rule', params: {
        'p_id': r['id'],
        'p_from': r['from_ad'],
        'p_to': r['to_ad'],
        'p_min': r['min_reward'],
        'p_max': r['max_reward'],
        'p_cooldown': r['cooldown_seconds'],
        'p_daily_limit': r['daily_limit'],
        'p_active': r['active'],
        'p_wait_after': r['wait_after_seconds'],
      });
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  Future<void> deleteWatchAdRule(String id) async {
    try {
      await Db.client.rpc('admin_delete_watch_ad_rule', params: {'p_id': id});
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  // ---- Search Card rules ---------------------------------------------------
  Future<List<Map<String, dynamic>>> searchRules() async {
    try {
      final res = await Db.client.rpc('admin_search_rules');
      return (res as List).map((e) => (e as Map).cast<String, dynamic>()).toList();
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  Future<void> saveSearchRule(Map<String, dynamic> r) async {
    try {
      await Db.client.rpc('admin_save_search_rule', params: {
        'p_id': r['id'],
        'p_from': r['from_search'],
        'p_to': r['to_search'],
        'p_min': r['min_reward'],
        'p_max': r['max_reward'],
        'p_cooldown': r['cooldown_seconds'],
        'p_wait_after': r['wait_after_seconds'],
        'p_daily_limit': r['daily_limit'],
        'p_active': r['active'],
      });
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  Future<void> deleteSearchRule(String id) async {
    try {
      await Db.client.rpc('admin_delete_search_rule', params: {'p_id': id});
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  Future<void> adjustBalance(String userId, int amount, String reason) async {
    try {
      await Db.client.rpc('admin_adjust_balance', params: {
        'p_user': userId,
        'p_amount': amount,
        'p_reason': reason,
      });
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  Future<void> setUserStatus(String userId, String status) async {
    try {
      await Db.client.rpc('admin_set_user_status',
          params: {'p_user': userId, 'p_status': status});
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  Future<List<Map<String, dynamic>>> users({String? search}) async {
    try {
      var q = Db.client
          .from('profiles')
          .select('id, email, full_name, status, referral_code, wallets(balance)');
      if (search != null && search.trim().isNotEmpty) {
        q = q.ilike('email', '%${search.trim()}%');
      }
      final rows = await q.order('created_at', ascending: false).limit(50);
      return (rows as List).map((e) => (e as Map).cast<String, dynamic>()).toList();
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  Future<void> setAdmin(String userId, bool grant) async {
    try {
      await Db.client.rpc('admin_set_admin',
          params: {'p_user': userId, 'p_grant': grant});
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  // ---- Task management -----------------------------------------------------
  Future<List<Map<String, dynamic>>> allTasks() async {
    try {
      final rows =
          await Db.client.from('tasks').select().order('position');
      return (rows as List).map((e) => (e as Map).cast<String, dynamic>()).toList();
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  Future<void> saveTask(Map<String, dynamic> t) async {
    try {
      await Db.client.rpc('admin_save_task', params: {
        'p_id': t['id'],
        'p_title': t['title'],
        'p_description': t['description'],
        'p_type': t['type'],
        'p_reward': t['reward'],
        'p_action_url': t['action_url'],
        'p_instructions': t['instructions'],
        'p_auto_verify': t['auto_verify'],
        'p_active': t['active'],
        'p_position': t['position'],
        'p_proof_method': t['proof_method'] ?? 'none',
        'p_proof_instruction': t['proof_instruction'],
        'p_requires_ad': t['requires_ad'] ?? false,
      });
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  Future<void> deleteTask(String id) async {
    try {
      await Db.client.rpc('admin_delete_task', params: {'p_id': id});
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  // ---- Quiz management -----------------------------------------------------
  Future<List<Map<String, dynamic>>> quizzes() async {
    try {
      final rows = await Db.client
          .from('quizzes')
          .select('id, quiz_date, title, reward, active, quiz_questions(count)')
          .order('quiz_date', ascending: false)
          .limit(60);
      return (rows as List).map((e) => (e as Map).cast<String, dynamic>()).toList();
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  Future<List<Map<String, dynamic>>> quizQuestions(String quizId) async {
    try {
      final rows = await Db.client
          .from('quiz_questions')
          .select()
          .eq('quiz_id', quizId)
          .order('position');
      return (rows as List).map((e) => (e as Map).cast<String, dynamic>()).toList();
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  Future<String> createQuiz(String date, String title, int reward) async {
    try {
      final res = await Db.client.rpc('admin_create_quiz',
          params: {'p_quiz_date': date, 'p_title': title, 'p_reward': reward});
      return (res as Map)['id'] as String;
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  Future<void> addQuizQuestion(String quizId, String question,
      List<String> options, int correctIndex, int position) async {
    try {
      await Db.client.rpc('admin_add_quiz_question', params: {
        'p_quiz_id': quizId,
        'p_question': question,
        'p_options': options,
        'p_correct_index': correctIndex,
        'p_position': position,
      });
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  Future<void> deleteQuizQuestion(String id) async {
    try {
      await Db.client.rpc('admin_delete_quiz_question', params: {'p_id': id});
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  /// Hard-delete a quiz. The server cascades its questions and attempts via
  /// foreign keys, so it disappears from the admin panel and becomes
  /// unavailable to users. A real error is thrown (and surfaced) on failure.
  Future<void> deleteQuiz(String id) async {
    try {
      await Db.client.rpc('admin_delete_quiz', params: {'p_id': id});
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  // ---- Payment methods -----------------------------------------------------
  Future<List<Map<String, dynamic>>> allPaymentMethods() async {
    try {
      final rows =
          await Db.client.from('payment_methods').select().order('position');
      return (rows as List).map((e) => (e as Map).cast<String, dynamic>()).toList();
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  Future<void> savePaymentMethod(Map<String, dynamic> m) async {
    try {
      await Db.client.rpc('admin_save_payment_method', params: {
        'p_id': m['id'],
        'p_key': m['key'],
        'p_name': m['name'],
        'p_fields': m['fields'],
        'p_min_amount': m['min_amount'],
        'p_active': m['active'],
        'p_position': m['position'],
        'p_currency': m['currency'],
        'p_rate': m['rate'],
        'p_rate_base': m['rate_base'],
        'p_fee_enabled': m['fee_enabled'],
        'p_fee_type': m['fee_type'],
        'p_fee_percent': m['fee_percent'],
        'p_fee_fixed': m['fee_fixed'],
      });
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  Future<void> deletePaymentMethod(String id) async {
    try {
      await Db.client
          .rpc('admin_delete_payment_method', params: {'p_id': id});
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  // ---- Audit logs ----------------------------------------------------------
  Future<List<Map<String, dynamic>>> auditLogs() async {
    try {
      final rows = await Db.client
          .from('audit_logs')
          .select()
          .order('created_at', ascending: false)
          .limit(100);
      return (rows as List).map((e) => (e as Map).cast<String, dynamic>()).toList();
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  // ---- Analytics (server-side filtered) ------------------------------------
  Future<Map<String, dynamic>> analytics(
      {DateTime? from, DateTime? to}) async {
    try {
      final res = await Db.client.rpc('admin_analytics', params: {
        'p_from': from?.toUtc().toIso8601String(),
        'p_to': to?.toUtc().toIso8601String(),
      });
      return (res as Map).cast<String, dynamic>();
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  Future<List<Map<String, dynamic>>> withdrawalsDetailed(String status) async {
    try {
      final res = await Db.client
          .rpc('admin_withdrawals', params: {'p_status': status});
      return (res as List).map((e) => (e as Map).cast<String, dynamic>()).toList();
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  // ---- Referral level configuration ----------------------------------------
  Future<void> setReferralLevels(
      List<Map<String, dynamic>> levels, bool enabled, num qualifying) async {
    try {
      await Db.client.rpc('admin_set_referral_levels', params: {
        'p_levels': levels,
        'p_enabled': enabled,
        'p_qualifying': qualifying,
      });
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  // ---- Referral fraud reviews ----------------------------------------------
  Future<List<Map<String, dynamic>>> referralReviews(String status) async {
    try {
      final res = await Db.client
          .rpc('admin_referral_reviews', params: {'p_status': status});
      return (res as List).map((e) => (e as Map).cast<String, dynamic>()).toList();
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  Future<void> resolveReferralReview(String id, bool approve) async {
    try {
      await Db.client.rpc('admin_resolve_referral_review',
          params: {'p_id': id, 'p_approve': approve});
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  // ---- Invite milestone claims ---------------------------------------------
  Future<List<Map<String, dynamic>>> inviteClaims(String status) async {
    try {
      final res = await Db.client
          .rpc('admin_invite_claims', params: {'p_status': status});
      return (res as List).map((e) => (e as Map).cast<String, dynamic>()).toList();
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  Future<void> resolveInviteClaim(String id, bool approve) async {
    try {
      await Db.client.rpc('admin_resolve_invite_claim',
          params: {'p_claim_id': id, 'p_approve': approve});
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  // ---- Invite milestone definitions ----------------------------------------
  Future<List<Map<String, dynamic>>> inviteMilestones() async {
    try {
      final rows = await Db.client
          .from('invite_milestones')
          .select()
          .order('position');
      return (rows as List).map((e) => (e as Map).cast<String, dynamic>()).toList();
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  Future<void> saveInviteMilestone(Map<String, dynamic> m) async {
    try {
      await Db.client.rpc('admin_save_invite_milestone', params: {
        'p_id': m['id'],
        'p_threshold': m['threshold'],
        'p_reward': m['reward'],
        'p_auto_verify': m['auto_verify'],
        'p_active': m['active'],
        'p_position': m['position'],
      });
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  Future<void> deleteInviteMilestone(String id) async {
    try {
      await Db.client
          .rpc('admin_delete_invite_milestone', params: {'p_id': id});
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  // ---- Contests ------------------------------------------------------------
  Future<List<Map<String, dynamic>>> contests() async {
    try {
      final rows =
          await Db.client.from('contests').select().order('position');
      return (rows as List).map((e) => (e as Map).cast<String, dynamic>()).toList();
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  Future<void> saveContest(Map<String, dynamic> c) async {
    try {
      await Db.client.rpc('admin_save_contest', params: {
        'p_id': c['id'],
        'p_name': c['name'],
        'p_target_type': c['target_type'],
        'p_target_value': c['target_value'],
        'p_reward': c['reward'],
        'p_duration_hours': c['duration_hours'],
        'p_requires_ad': c['requires_ad'],
        'p_rules': c['rules'],
        'p_active': c['active'],
        'p_position': c['position'],
      });
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  Future<void> deleteContest(String id) async {
    try {
      await Db.client.rpc('admin_delete_contest', params: {'p_id': id});
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  Future<List<Map<String, dynamic>>> contestClaims(String status) async {
    try {
      final res = await Db.client
          .rpc('admin_contest_claims', params: {'p_status': status});
      return (res as List).map((e) => (e as Map).cast<String, dynamic>()).toList();
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  Future<void> resolveContestClaim(String id, bool approve) async {
    try {
      await Db.client.rpc('admin_resolve_contest_claim',
          params: {'p_id': id, 'p_approve': approve});
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  // ---- Configurable links --------------------------------------------------
  Future<List<Map<String, dynamic>>> appLinks() async {
    try {
      final res = await Db.client.rpc('admin_app_links');
      return (res as List).map((e) => (e as Map).cast<String, dynamic>()).toList();
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  Future<void> saveAppLink(Map<String, dynamic> l) async {
    try {
      await Db.client.rpc('admin_save_app_link', params: {
        'p_id': l['id'],
        'p_key': l['key'],
        'p_label': l['label'],
        'p_url': l['url'],
        'p_icon': l['icon'],
        'p_external': l['external'],
        'p_position': l['position'],
        'p_active': l['active'],
      });
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  Future<void> deleteAppLink(String id) async {
    try {
      await Db.client.rpc('admin_delete_app_link', params: {'p_id': id});
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  // ---- User detail ---------------------------------------------------------
  Future<List<Map<String, dynamic>>> userTransactions(String userId) async {
    try {
      final rows = await Db.client
          .from('wallet_transactions')
          .select()
          .eq('user_id', userId)
          .order('created_at', ascending: false)
          .limit(50);
      return (rows as List).map((e) => (e as Map).cast<String, dynamic>()).toList();
    } catch (e) {
      throw AppFailure.from(e);
    }
  }
}
