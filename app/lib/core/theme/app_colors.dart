import 'package:flutter/material.dart';

/// BlueChip Rewards palette — a premium deep-blue + gold reward system.
class AppColors {
  AppColors._();

  // Brand
  static const primary = Color(0xFF2563EB); // BlueChip blue
  static const primaryDark = Color(0xFF1E40AF);
  static const primaryLight = Color(0xFF60A5FA);
  static const gold = Color(0xFFF5B301); // reward gold
  static const goldDark = Color(0xFFD99A00);

  // Semantic
  static const success = Color(0xFF16A34A);
  static const warning = Color(0xFFF59E0B);
  static const danger = Color(0xFFDC2626);
  static const info = Color(0xFF0EA5E9);

  // Light surfaces
  static const bg = Color(0xFFF6F8FC);
  static const surface = Color(0xFFFFFFFF);
  static const surfaceAlt = Color(0xFFEFF3FA);
  static const textPrimary = Color(0xFF0F172A);
  static const textSecondary = Color(0xFF64748B);
  static const border = Color(0xFFE2E8F0);

  // Gradients
  static const heroGradient = LinearGradient(
    colors: [Color(0xFF1E3A8A), Color(0xFF2563EB), Color(0xFF3B82F6)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
  static const goldGradient = LinearGradient(
    colors: [Color(0xFFF5B301), Color(0xFFFFD65A)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
}
