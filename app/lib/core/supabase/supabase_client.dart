import 'package:supabase_flutter/supabase_flutter.dart';
import '../config/app_config.dart';

/// Thin accessor around the initialised Supabase singleton.
class Db {
  Db._();

  static Future<void> init() async {
    await Supabase.initialize(
      url: AppConfig.supabaseUrl,
      anonKey: AppConfig.supabaseAnonKey,
      authOptions: const FlutterAuthClientOptions(
        authFlowType: AuthFlowType.pkce,
      ),
    );
  }

  static SupabaseClient get client => Supabase.instance.client;
  static GoTrueClient get auth => Supabase.instance.client.auth;
  static User? get user => auth.currentUser;
  static String? get uid => auth.currentUser?.id;
}
