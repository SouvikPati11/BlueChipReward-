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
}
