import 'package:flutter/material.dart';
import 'app_colors.dart';

/// Theme-aware semantic surfaces/text. Brand colours (primary, gold, semantic)
/// stay constant across themes; only neutrals flip between light and dark.
@immutable
class AppPalette extends ThemeExtension<AppPalette> {
  final Color scaffold;
  final Color surface;
  final Color surfaceAlt;
  final Color border;
  final Color textPrimary;
  final Color textSecondary;

  const AppPalette({
    required this.scaffold,
    required this.surface,
    required this.surfaceAlt,
    required this.border,
    required this.textPrimary,
    required this.textSecondary,
  });

  static const light = AppPalette(
    scaffold: AppColors.bg,
    surface: AppColors.surface,
    surfaceAlt: AppColors.surfaceAlt,
    border: AppColors.border,
    textPrimary: AppColors.textPrimary,
    textSecondary: AppColors.textSecondary,
  );

  static const dark = AppPalette(
    scaffold: Color(0xFF0B1220),
    surface: Color(0xFF111E33),
    surfaceAlt: Color(0xFF18263F),
    border: Color(0xFF25344B),
    textPrimary: Color(0xFFE7EEFB),
    textSecondary: Color(0xFF9AA8BD),
  );

  @override
  AppPalette copyWith({
    Color? scaffold,
    Color? surface,
    Color? surfaceAlt,
    Color? border,
    Color? textPrimary,
    Color? textSecondary,
  }) =>
      AppPalette(
        scaffold: scaffold ?? this.scaffold,
        surface: surface ?? this.surface,
        surfaceAlt: surfaceAlt ?? this.surfaceAlt,
        border: border ?? this.border,
        textPrimary: textPrimary ?? this.textPrimary,
        textSecondary: textSecondary ?? this.textSecondary,
      );

  @override
  AppPalette lerp(ThemeExtension<AppPalette>? other, double t) {
    if (other is! AppPalette) return this;
    return AppPalette(
      scaffold: Color.lerp(scaffold, other.scaffold, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceAlt: Color.lerp(surfaceAlt, other.surfaceAlt, t)!,
      border: Color.lerp(border, other.border, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
    );
  }
}

/// `context.cx.surface`, `context.cx.textSecondary`, etc.
extension AppPaletteX on BuildContext {
  AppPalette get cx =>
      Theme.of(this).extension<AppPalette>() ?? AppPalette.light;
}
