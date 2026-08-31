import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'repositories.dart';

/// Streams Supabase auth state so the router can react to sign-in/out.
final authStateProvider = StreamProvider<AuthState>((ref) {
  return ref.watch(authRepositoryProvider).authState;
});

/// Convenience: the current session (recomputed whenever auth state changes).
final sessionProvider = Provider<Session?>((ref) {
  ref.watch(authStateProvider);
  return Supabase.instance.client.auth.currentSession;
});

final isSignedInProvider = Provider<bool>((ref) {
  ref.watch(authStateProvider);
  return Supabase.instance.client.auth.currentSession != null;
});

/// Server-verified admin role (used only to reveal admin UI; every admin action
/// is independently authorised server-side).
final isAdminProvider = FutureProvider<bool>((ref) async {
  ref.watch(authStateProvider);
  if (Supabase.instance.client.auth.currentSession == null) return false;
  return ref.watch(userRepositoryProvider).isAdmin();
});
