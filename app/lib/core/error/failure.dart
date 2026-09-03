import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException, MissingPluginException;
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

    // Development diagnostics: log the REAL exception type + message so the
    // exact failing operation is visible in `flutter run` / logcat. This runs
    // only in debug/profile builds (assert) and never includes secrets — the
    // Supabase anon key / service-role key are not part of any error object.
    assert(() {
      debugPrint('AppFailure.from → ${error.runtimeType}: $error');
      return true;
    }());

    if (error is PostgrestException) {
      final raw = error.message;
      // our functions raise codes like ACCOUNT_BANNED / ALREADY_CLAIMED
      final code = _extractCode(raw);
      return AppFailure(code, _messages[code] ?? _clean(raw));
    }
    if (error is AuthException) {
      // Real auth outcome (invalid credentials, disabled user, etc.) — map the
      // common cases to friendly text and pass the rest through as-is.
      return AppFailure('AUTH', _friendlyAuth(error.message));
    }

    // A native plugin threw across the platform channel (storage/keystore/etc).
    // The code + message are safe to surface (they are not secrets) and are
    // exactly what identifies the offending native operation. Full details go
    // to the log only (still no secrets — plugin errors don't carry the key).
    if (error is MissingPluginException) {
      return AppFailure('PLUGIN',
          'A required app component is missing (${error.message ?? 'MissingPlugin'}). Please reinstall the app.');
    }
    if (error is PlatformException) {
      final code = error.code.trim();
      final msg = (error.message ?? '').trim();
      final blob = '$code $msg';
      // Google Sign-In (google_sign_in plugin) failures — actionable messages.
      // These come ONLY from the "Continue with Google" flow, never from
      // email/password sign-in.
      if (code == 'sign_in_failed' || blob.contains('ApiException')) {
        if (blob.contains('ApiException: 10') || blob.contains('DEVELOPER_ERROR')) {
          return const AppFailure('GOOGLE_CONFIG',
              'Google Sign-In isn\'t configured for this build yet. Please sign in with your email and password.');
        }
        if (blob.contains('ApiException: 7') || blob.contains('NETWORK')) {
          return const AppFailure('GOOGLE_NETWORK',
              'Network problem during Google Sign-In. Check your connection and try again.');
        }
        if (blob.contains('12501') || blob.toLowerCase().contains('cancel')) {
          return const AppFailure('CANCELLED', 'Sign-in cancelled.');
        }
        return AppFailure('GOOGLE',
            'Google Sign-In couldn\'t complete ($code). Please try email & password.');
      }
      final shown = msg.isEmpty ? code : '$code — $msg';
      return AppFailure('PLATFORM',
          'Sign-in couldn\'t complete on this device (PlatformException: $shown). Please try again.');
    }

    // Everything below is NOT an authentication failure — distinguishing these
    // is important so a network/config problem is never shown as "wrong
    // password" (and vice-versa).
    final text = error.toString();
    if (error is SocketException ||
        error is TimeoutException ||
        error is HttpException ||
        error is HandshakeException ||
        _looksNetwork(text)) {
      return AppFailure('NETWORK',
          'Network connection problem. Check your internet and try again.');
    }
    if (error is FormatException || text.contains('FormatException')) {
      // A non-JSON response usually means the Supabase URL/endpoint is wrong.
      return AppFailure('CONFIG',
          'Server connection problem. Please try again in a moment.');
    }
    // Truly unexpected: include the exception's type (a class name, not a
    // secret) so the exact failure is identifiable from a screenshot/log.
    return AppFailure(
        'UNKNOWN', 'Something went wrong (${error.runtimeType}). Please try again.');
  }

  static bool _looksNetwork(String s) {
    final l = s.toLowerCase();
    return l.contains('socketexception') ||
        l.contains('clientexception') ||
        l.contains('failed host lookup') ||
        l.contains('connection closed') ||
        l.contains('connection refused') ||
        l.contains('connection reset') ||
        l.contains('network is unreachable') ||
        l.contains('handshake') ||
        l.contains('timed out') ||
        l.contains('timeout');
  }

  static String _friendlyAuth(String raw) {
    final l = raw.toLowerCase();
    if (l.contains('invalid login credentials') ||
        l.contains('invalid credentials')) {
      return 'Invalid email or password.';
    }
    if (l.contains('email not confirmed')) {
      return 'Please confirm your email before signing in.';
    }
    if (l.contains('invalid api key') || l.contains('api key')) {
      // A key/URL mismatch is a configuration problem, not the user's fault.
      return 'Server configuration problem. Please try again later.';
    }
    if (_looksNetwork(l)) {
      return 'Network connection problem. Check your internet and try again.';
    }
    return raw.isEmpty ? 'Sign-in failed. Please try again.' : raw;
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
