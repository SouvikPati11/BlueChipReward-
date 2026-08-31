class Profile {
  final String id;
  final String? email;
  final String? fullName;
  final String? username;
  final String? avatarUrl;
  final String referralCode;
  final String? referredBy;
  final String status;

  const Profile({
    required this.id,
    this.email,
    this.fullName,
    this.username,
    this.avatarUrl,
    required this.referralCode,
    this.referredBy,
    required this.status,
  });

  factory Profile.fromJson(Map<String, dynamic> j) => Profile(
        id: j['id'] as String,
        email: j['email'] as String?,
        fullName: j['full_name'] as String?,
        username: j['username'] as String?,
        avatarUrl: j['avatar_url'] as String?,
        referralCode: j['referral_code'] as String? ?? '',
        referredBy: j['referred_by'] as String?,
        status: j['status'] as String? ?? 'active',
      );

  String get displayName =>
      (fullName?.trim().isNotEmpty ?? false) ? fullName! : (email ?? 'User');

  String get initials {
    final n = displayName.trim();
    if (n.isEmpty) return 'U';
    final parts = n.split(RegExp(r'\s+'));
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts[0][0] + parts[1][0]).toUpperCase();
  }
}

class Wallet {
  final int balance;
  final int totalEarned;
  final int totalWithdrawn;
  final int pendingWithdrawal;

  const Wallet({
    required this.balance,
    required this.totalEarned,
    required this.totalWithdrawn,
    required this.pendingWithdrawal,
  });

  const Wallet.empty()
      : balance = 0,
        totalEarned = 0,
        totalWithdrawn = 0,
        pendingWithdrawal = 0;

  factory Wallet.fromJson(Map<String, dynamic> j) => Wallet(
        balance: (j['balance'] as num?)?.toInt() ?? 0,
        totalEarned: (j['total_earned'] as num?)?.toInt() ?? 0,
        totalWithdrawn: (j['total_withdrawn'] as num?)?.toInt() ?? 0,
        pendingWithdrawal: (j['pending_withdrawal'] as num?)?.toInt() ?? 0,
      );
}

class WalletTransaction {
  final String id;
  final int amount;
  final int balanceAfter;
  final String type;
  final String? description;
  final DateTime createdAt;

  const WalletTransaction({
    required this.id,
    required this.amount,
    required this.balanceAfter,
    required this.type,
    this.description,
    required this.createdAt,
  });

  factory WalletTransaction.fromJson(Map<String, dynamic> j) =>
      WalletTransaction(
        id: j['id'] as String,
        amount: (j['amount'] as num).toInt(),
        balanceAfter: (j['balance_after'] as num).toInt(),
        type: j['type'] as String,
        description: j['description'] as String?,
        createdAt: DateTime.parse(j['created_at'] as String),
      );

  bool get isCredit => amount >= 0;
}
