import 'package:supabase_flutter/supabase_flutter.dart';

/// A user-presentable failure. Maps backend error codes (raised as Postgres
/// exceptions by our SECURITY DEFINER functions) to friendly messages.
class AppFailure implements Exception {
  final String code;
  final String message;
  const AppFailure(this.code, this.message);

  @override
  String toString() => message;

  static const _messages = <String, String>{
    'UNAUTHENTICATED': 'Please sign in to continue.',
    'PROFILE_NOT_FOUND': 'Your profile could not be found.',
    'ACCOUNT_SUSPENDED': 'Your account is suspended. Contact support.',
    'ACCOUNT_BANNED': 'Your account has been banned.',
    'ALREADY_CLAIMED': 'You have already claimed today. Come back tomorrow!',
    'MINING_ALREADY_ACTIVE': 'A mining session is already running.',
    'NO_ACTIVE_MINING': 'Start a mining session first.',
    'NOTHING_TO_CLAIM': 'Nothing to claim yet — keep mining!',
    'CARD_NOT_FOUND': 'Scratch card not found.',
    'CARD_ALREADY_USED': 'This card has already been scratched.',
    'AD_DAILY_LIMIT': 'You have reached today\'s ad limit.',
    'AD_TOO_SOON': 'Please wait a moment before the next ad.',
    'AD_REQUIRED': 'Watch the ad to earn this reward.',
    'AD_NOT_COMPLETED': 'Please watch the full ad to earn your reward.',
    'AD_ALREADY_USED': 'That ad reward was already claimed.',
    'MAX_BOOSTS': 'You\'ve used all boosts for this session.',
    'BOOST_COOLDOWN': 'Boost is on cooldown. Try again a bit later.',
    'SESSION_ENDED': 'This mining session has ended.',
    'MILESTONE_NOT_REACHED': 'You haven\'t reached this milestone yet.',
    'MILESTONE_UNAVAILABLE': 'This milestone is not available.',
    'PROOF_REQUIRED': 'A proof screenshot is required.',
    'QUIZ_NOT_FOUND': 'No quiz is available right now.',
    'ALREADY_ATTEMPTED': 'You have already completed today\'s quiz.',
    'TASK_NOT_FOUND': 'This task is no longer available.',
    'TASK_ALREADY_DONE': 'You have already completed this task.',
    'INSUFFICIENT_BALANCE': 'Insufficient BCP balance.',
    'INVALID_AMOUNT': 'Enter a valid amount.',
    'METHOD_UNAVAILABLE': 'This payment method is unavailable.',
    'BELOW_MINIMUM': 'Amount is below the minimum withdrawal.',
    'WITHDRAWAL_IN_PROGRESS': 'You already have a withdrawal in progress.',
    'FORBIDDEN': 'You are not authorised to perform this action.',
  };

  factory AppFailure.from(Object error) {
    if (error is AppFailure) return error;
    if (error is PostgrestException) {
      final raw = error.message;
      // our functions raise codes like ACCOUNT_BANNED / ALREADY_CLAIMED
      final code = _extractCode(raw);
      return AppFailure(code, _messages[code] ?? _clean(raw));
    }
    if (error is AuthException) {
      return AppFailure('AUTH', error.message);
    }
    return AppFailure('UNKNOWN', 'Something went wrong. Please try again.');
  }

  static String _extractCode(String raw) {
    for (final key in _messages.keys) {
      if (raw.contains(key)) return key;
    }
    return 'UNKNOWN';
  }

  static String _clean(String raw) {
    // strip the postgres prefix if present
    final idx = raw.indexOf(':');
    final s = idx >= 0 && idx < 40 ? raw.substring(idx + 1).trim() : raw;
    return s.isEmpty ? 'Something went wrong.' : s;
  }
}
