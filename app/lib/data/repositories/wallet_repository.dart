import '../../core/error/failure.dart';
import '../../core/supabase/supabase_client.dart';
import '../../models/wallet_models.dart';

class WalletRepository {
  Future<List<PaymentMethod>> fetchPaymentMethods() async {
    try {
      final rows = await Db.client
          .from('payment_methods')
          .select()
          .eq('active', true)
          .order('position');
      return (rows as List)
          .map((e) => PaymentMethod.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  Future<int> minWithdrawal() async {
    try {
      final row = await Db.client
          .from('app_settings')
          .select('value')
          .eq('key', 'withdrawal_min')
          .maybeSingle();
      if (row == null) return 1000;
      return int.tryParse(row['value'].toString()) ?? 1000;
    } catch (_) {
      return 1000;
    }
  }

  Future<String> requestWithdrawal({
    required int amount,
    required String methodKey,
    required Map<String, dynamic> details,
  }) async {
    try {
      final res = await Db.client.rpc('request_withdrawal', params: {
        'p_amount': amount,
        'p_method_key': methodKey,
        'p_details': details,
      });
      return (res as Map)['withdrawal_id'] as String;
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  /// Server-authoritative conversion + fee quote for the withdraw screen.
  Future<Map<String, dynamic>> withdrawalQuote(
      String methodKey, int amount) async {
    try {
      final res = await Db.client.rpc('withdrawal_quote',
          params: {'p_method_key': methodKey, 'p_amount': amount});
      return (res as Map).cast<String, dynamic>();
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  Future<List<Withdrawal>> fetchWithdrawals() async {
    try {
      final uid = Db.uid!;
      final rows = await Db.client
          .from('withdrawals')
          .select()
          .eq('user_id', uid)
          .order('created_at', ascending: false);
      return (rows as List)
          .map((e) => Withdrawal.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  Future<ReferralStats> fetchReferralStats(String referralCode) async {
    try {
      final uid = Db.uid!;
      // Server-authoritative level-wise overview (counts, earnings, per-level
      // reward config). Falls back gracefully if the RPC is unavailable.
      List<ReferralLevel> levels = const [];
      int totalReferrals = 0;
      int totalEarned = 0;
      String code = referralCode;
      try {
        final overview = await Db.client.rpc('referral_overview');
        final map = (overview as Map).cast<String, dynamic>();
        code = (map['code'] as String?) ?? referralCode;
        totalReferrals = (map['total_referrals'] as num?)?.toInt() ?? 0;
        totalEarned = (map['total_earnings'] as num?)?.toInt() ?? 0;
        levels = ((map['per_level'] as List?) ?? const [])
            .map((e) => ReferralLevel.fromJson((e as Map).cast<String, dynamic>()))
            .toList();
      } catch (_) {
        // RPC not deployed yet — the recent-list aggregate below still works.
      }

      final rows = await Db.client
          .from('referrals')
          .select('reward_amount, level, created_at')
          .eq('referrer_id', uid)
          .order('created_at', ascending: false);
      final list = (rows as List)
          .map((e) => ReferralEntry.fromJson(e as Map<String, dynamic>))
          .toList();

      // Fall back to client aggregation if the RPC was unavailable.
      if (levels.isEmpty) {
        totalReferrals = list.length;
        totalEarned = list.fold<int>(0, (s, e) => s + e.reward);
      }

      return ReferralStats(
        referralCode: code,
        totalReferrals: totalReferrals,
        totalEarned: totalEarned,
        recent: list.take(20).toList(),
        levels: levels,
      );
    } catch (e) {
      throw AppFailure.from(e);
    }
  }
}
