import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/supabase/supabase_client.dart';

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
    // Deep-navy field that matches the logo's own background so the mark blends
    // in seamlessly (no "sticker" edge), with a subtle brand-blue glow.
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF0A2E7A), Color(0xFF01143F)],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: const Duration(milliseconds: 650),
              curve: Curves.easeOutCubic,
              builder: (context, t, child) => Opacity(
                opacity: t.clamp(0.0, 1.0),
                child: Transform.scale(scale: 0.92 + 0.08 * t, child: child),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // The exact official logo (it already carries the wordmark),
                  // so no separate app-name text is needed.
                  SizedBox(
                    width: 168,
                    height: 168,
                    child: Image.asset(
                      'assets/branding/logo.png',
                      fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) => const Icon(
                          Icons.diamond_rounded,
                          color: Colors.white,
                          size: 96),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text('Earn BCP. Complete activities. Get rewarded.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: .82),
                          fontSize: 14,
                          fontWeight: FontWeight.w500)),
                  const SizedBox(height: 34),
                  // Elegant, low-key progress hint (not a big spinner).
                  SizedBox(
                    width: 120,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        minHeight: 3,
                        backgroundColor: Colors.white.withValues(alpha: .16),
                        valueColor: AlwaysStoppedAnimation(
                            Colors.white.withValues(alpha: .9)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
