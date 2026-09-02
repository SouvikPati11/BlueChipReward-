import '../../core/error/failure.dart';
import '../../core/supabase/supabase_client.dart';
import '../../models/wallet_models.dart';

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
