import '../../core/error/failure.dart';
import '../../core/supabase/supabase_client.dart';
import '../../models/profile.dart';
import '../../models/wallet_models.dart';

class UserRepository {
  Future<Profile> fetchProfile() async {
    try {
      final uid = Db.uid!;
      final row = await Db.client
          .from('profiles')
          .select()
          .eq('id', uid)
          .single();
      return Profile.fromJson(row);
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  Future<bool> isAdmin() async {
    try {
      final uid = Db.uid;
      if (uid == null) return false;
      final rows = await Db.client
          .from('user_roles')
          .select('role')
          .eq('user_id', uid)
          .eq('role', 'admin');
      return (rows as List).isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<Wallet> fetchWallet() async {
    try {
      final uid = Db.uid!;
      final row = await Db.client
          .from('wallets')
          .select()
          .eq('user_id', uid)
          .maybeSingle();
      return row == null ? const Wallet.empty() : Wallet.fromJson(row);
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  Future<List<WalletTransaction>> fetchTransactions({int limit = 50}) async {
    try {
      final uid = Db.uid!;
      final rows = await Db.client
          .from('wallet_transactions')
          .select()
          .eq('user_id', uid)
          .order('created_at', ascending: false)
          .limit(limit);
      return (rows as List)
          .map((e) => WalletTransaction.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  Future<void> updateProfile(
      {String? fullName, String? username, String? avatarUrl}) async {
    try {
      final uid = Db.uid!;
      final patch = <String, dynamic>{};
      if (fullName != null) patch['full_name'] = fullName;
      if (username != null) patch['username'] = username;
      if (avatarUrl != null) patch['avatar_url'] = avatarUrl;
      if (patch.isEmpty) return;
      await Db.client.from('profiles').update(patch).eq('id', uid);
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  Future<List<AppNotification>> fetchNotifications({int limit = 50}) async {
    try {
      final rows = await Db.client
          .from('notifications')
          .select()
          .order('created_at', ascending: false)
          .limit(limit);
      return (rows as List)
          .map((e) => AppNotification.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  Future<void> markNotificationRead(String id) async {
    try {
      await Db.client.from('notifications').update({'read': true}).eq('id', id);
    } catch (_) {}
  }
}
