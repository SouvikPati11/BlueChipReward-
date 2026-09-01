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
