class PaymentMethod {
  final String key;
  final String name;
  final int minAmount;
  final List<PaymentField> fields;

  const PaymentMethod({
    required this.key,
    required this.name,
    required this.minAmount,
    required this.fields,
  });

  factory PaymentMethod.fromJson(Map<String, dynamic> j) => PaymentMethod(
        key: j['key'] as String,
        name: j['name'] as String,
        minAmount: (j['min_amount'] as num?)?.toInt() ?? 0,
        fields: ((j['fields'] as List?) ?? [])
            .map((e) => PaymentField.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class PaymentField {
  final String key;
  final String label;
  final String type;

  const PaymentField(
      {required this.key, required this.label, required this.type});

  factory PaymentField.fromJson(Map<String, dynamic> j) => PaymentField(
        key: j['key'] as String,
        label: j['label'] as String,
        type: j['type'] as String? ?? 'text',
      );
}

class Withdrawal {
  final String id;
  final int amount;
  final String methodKey;
  final String status;
  final String? adminNotes;
  final DateTime createdAt;

  const Withdrawal({
    required this.id,
    required this.amount,
    required this.methodKey,
    required this.status,
    this.adminNotes,
    required this.createdAt,
  });

  factory Withdrawal.fromJson(Map<String, dynamic> j) => Withdrawal(
        id: j['id'] as String,
        amount: (j['amount'] as num).toInt(),
        methodKey: j['method_key'] as String,
        status: j['status'] as String,
        adminNotes: j['admin_notes'] as String?,
        createdAt: DateTime.parse(j['created_at'] as String),
      );
}

class ReferralStats {
  final String referralCode;
  final int totalReferrals;
  final int totalEarned;
  final List<ReferralEntry> recent;

  const ReferralStats({
    required this.referralCode,
    required this.totalReferrals,
    required this.totalEarned,
    required this.recent,
  });
}

class ReferralEntry {
  final int reward;
  final DateTime createdAt;
  const ReferralEntry({required this.reward, required this.createdAt});

  factory ReferralEntry.fromJson(Map<String, dynamic> j) => ReferralEntry(
        reward: (j['reward_amount'] as num?)?.toInt() ?? 0,
        createdAt: DateTime.parse(j['created_at'] as String),
      );
}

class AppNotification {
  final String id;
  final String title;
  final String? body;
  final String type;
  final bool read;
  final DateTime createdAt;

  const AppNotification({
    required this.id,
    required this.title,
    this.body,
    required this.type,
    required this.read,
    required this.createdAt,
  });

  factory AppNotification.fromJson(Map<String, dynamic> j) => AppNotification(
        id: j['id'] as String,
        title: j['title'] as String,
        body: j['body'] as String?,
        type: j['type'] as String? ?? 'system',
        read: j['read'] as bool? ?? false,
        createdAt: DateTime.parse(j['created_at'] as String),
      );
}
