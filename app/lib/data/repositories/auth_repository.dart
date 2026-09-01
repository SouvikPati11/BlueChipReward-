import 'package:google_sign_in/google_sign_in.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/config/app_config.dart';
import '../../core/error/failure.dart';
import '../../core/supabase/supabase_client.dart';
import '../../core/utils/device_id.dart';

class AuthRepository {
  GoTrueClient get _auth => Db.auth;

  Stream<AuthState> get authState => _auth.onAuthStateChange;
  User? get currentUser => _auth.currentUser;

  Future<void> signUpEmail({
    required String email,
    required String password,
    required String fullName,
    String? referralCode,
  }) async {
    try {
      final deviceId = await DeviceId.get();
      await _auth.signUp(
        email: email,
        password: password,
        data: {
          'full_name': fullName,
          'device_id': deviceId,
          if (referralCode != null && referralCode.trim().isNotEmpty)
            'referral_code': referralCode.trim().toUpperCase(),
        },
      );
      await _registerDevice();
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  Future<void> signInEmail(
      {required String email, required String password}) async {
    try {
      await _auth.signInWithPassword(email: email, password: password);
      await _registerDevice();
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  /// Best-effort: record this install's device id for same-device fraud checks.
  Future<void> _registerDevice() async {
    try {
      final deviceId = await DeviceId.get();
      await Db.client.rpc('register_device', params: {'p_device_id': deviceId});
    } catch (_) {
      // non-fatal
    }
  }

  /// Native Google Sign-In → Supabase via ID token. Referral (if provided) is
  /// applied afterwards through a server RPC, which is a no-op if the profile
  /// was already referred.
  Future<void> signInWithGoogle({String? referralCode}) async {
    try {
      final webClientId = AppConfig.googleWebClientId;
      final google = GoogleSignIn(
          serverClientId: webClientId.isEmpty ? null : webClientId);
      final account = await google.signIn();
      if (account == null) {
        throw const AppFailure('CANCELLED', 'Sign-in cancelled.');
      }
      final auth = await account.authentication;
      final idToken = auth.idToken;
      final accessToken = auth.accessToken;
      if (idToken == null) {
        throw const AppFailure('AUTH', 'Google sign-in failed (no ID token).');
      }
      await _auth.signInWithIdToken(
        provider: OAuthProvider.google,
        idToken: idToken,
        accessToken: accessToken,
      );
      // Record device before applying a referral so the same-device abuse
      // check has the signal available.
      await _registerDevice();
      if (referralCode != null && referralCode.trim().isNotEmpty) {
        try {
          await Db.client.rpc('apply_referral_code',
              params: {'p_code': referralCode.trim().toUpperCase()});
        } catch (_) {
          // best-effort; ignore if already referred / invalid
        }
      }
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  Future<void> resetPassword(String email) async {
    try {
      await _auth.resetPasswordForEmail(email);
    } catch (e) {
      throw AppFailure.from(e);
    }
  }

  Future<void> signOut() async {
    try {
      await GoogleSignIn().signOut().catchError((_) => null);
      await _auth.signOut();
    } catch (e) {
      throw AppFailure.from(e);
    }
  }
}
