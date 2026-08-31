import 'package:intl/intl.dart';

class Fmt {
  Fmt._();

  static final _num = NumberFormat.decimalPattern();
  static final _date = DateFormat('MMM d, yyyy');
  static final _dateTime = DateFormat('MMM d, h:mm a');

  static String points(num v) => _num.format(v);
  static String date(DateTime d) => _date.format(d.toLocal());
  static String dateTime(DateTime d) => _dateTime.format(d.toLocal());

  static String duration(Duration d) {
    if (d.isNegative) d = Duration.zero;
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    if (h > 0) return '${h}h ${m}m';
    if (m > 0) return '${m}m ${s}s';
    return '${s}s';
  }

  static String timeAgo(DateTime d) {
    final diff = DateTime.now().difference(d.toLocal());
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return date(d);
  }

  static String txLabel(String type) {
    switch (type) {
      case 'daily_reward':
        return 'Daily Reward';
      case 'mining':
        return 'Mining';
      case 'scratch':
        return 'Scratch Card';
      case 'ad':
        return 'Watch Ad';
      case 'quiz':
        return 'Daily Quiz';
      case 'task':
        return 'Task';
      case 'referral':
        return 'Referral';
      case 'signup_bonus':
        return 'Welcome Bonus';
      case 'withdrawal_hold':
        return 'Withdrawal';
      case 'withdrawal_refund':
        return 'Withdrawal Refund';
      case 'admin_adjustment':
        return 'Adjustment';
      default:
        return type;
    }
  }
}
