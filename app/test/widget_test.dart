import 'package:bluechip_rewards/core/error/failure.dart';
import 'package:bluechip_rewards/core/utils/formatters.dart';
import 'package:bluechip_rewards/models/profile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Fmt', () {
    test('formats points with separators', () {
      expect(Fmt.points(1000), '1,000');
    });

    test('maps ledger types to labels', () {
      expect(Fmt.txLabel('daily_reward'), 'Daily Reward');
      expect(Fmt.txLabel('mining'), 'Mining');
      expect(Fmt.txLabel('unknown_type'), 'unknown_type');
    });

    test('formats durations', () {
      expect(Fmt.duration(const Duration(hours: 2, minutes: 5)), '2h 5m');
      expect(Fmt.duration(const Duration(seconds: -10)), '0s');
    });
  });

  group('Wallet', () {
    test('empty wallet has zero balances', () {
      const w = Wallet.empty();
      expect(w.balance, 0);
      expect(w.totalEarned, 0);
    });

    test('parses from json', () {
      final w = Wallet.fromJson({
        'balance': 500,
        'total_earned': 800,
        'total_withdrawn': 100,
        'pending_withdrawal': 50,
      });
      expect(w.balance, 500);
      expect(w.totalWithdrawn, 100);
    });
  });

  group('Profile', () {
    test('computes initials', () {
      const p = Profile(
        id: 'x',
        fullName: 'Souvik Pati',
        referralCode: 'BCP123',
        status: 'active',
      );
      expect(p.initials, 'SP');
      expect(p.displayName, 'Souvik Pati');
    });
  });

  group('AppFailure', () {
    test('maps known codes to friendly messages', () {
      const f = AppFailure('ALREADY_CLAIMED', 'x');
      expect(f.code, 'ALREADY_CLAIMED');
    });
  });
}
