import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/config/constants.dart';
import '../../core/supabase/supabase_client.dart';
import '../../core/theme/app_colors.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _decide();
  }

  Future<void> _decide() async {
    await Future.delayed(const Duration(milliseconds: 700));
    if (!mounted) return;
    final signedIn = Db.auth.currentSession != null;
    context.go(signedIn ? '/home' : '/login');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: AppColors.heroGradient),
        child: Center(
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: const Duration(milliseconds: 600),
            curve: Curves.easeOutBack,
            builder: (context, t, child) => Opacity(
              opacity: t.clamp(0.0, 1.0),
              child: Transform.scale(scale: 0.9 + 0.1 * t, child: child),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 100,
                  height: 100,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: .15),
                    borderRadius: BorderRadius.circular(28),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Image.asset(
                    'assets/branding/logo.png',
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const Icon(
                        Icons.diamond_rounded,
                        color: Colors.white,
                        size: 52),
                  ),
                ),
                const SizedBox(height: 24),
                const Text(K.appName,
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 26,
                        fontWeight: FontWeight.w900)),
                const SizedBox(height: 8),
                Text('Earn BCP. Complete activities. Get rewarded.',
                    textAlign: TextAlign.center,
                    style:
                        TextStyle(color: Colors.white.withValues(alpha: .85))),
                const SizedBox(height: 40),
                const SizedBox(
                  width: 26,
                  height: 26,
                  child: CircularProgressIndicator(
                      strokeWidth: 2.5, color: Colors.white),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
