import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import 'app_colors.dart';

class AppTheme {
  AppTheme._();

  static const String fontFamily = 'Poppins';

  /// [primary]/[secondary]/[fontFamilyOverride] come from the admin-panel
  /// -editable `app_config` row (via [ThemeConfigController]) when
  /// available; omitted, this renders exactly as the hardcoded defaults
  /// always have. A [fontFamilyOverride] other than 'Poppins' is fetched
  /// live via google_fonts — 'Poppins' itself always uses the bundled
  /// asset (no network dependency for the default look).
  static ThemeData dark({Color? primary, Color? secondary, String? fontFamilyOverride}) {
    final effectivePrimary = primary ?? AppColors.primary;
    final effectiveSecondary = secondary ?? AppColors.magenta;
    final effectiveFont = fontFamilyOverride ?? fontFamily;

    final base = ThemeData.dark(useMaterial3: true);
    final scheme = ColorScheme.dark(
      primary: effectivePrimary,
      secondary: effectiveSecondary,
      surface: AppColors.surface,
      error: AppColors.danger,
      onPrimary: Colors.white,
      onSurface: AppColors.textPrimary,
    );

    return base.copyWith(
      colorScheme: scheme,
      scaffoldBackgroundColor: AppColors.bg,
      canvasColor: AppColors.bg,
      primaryColor: effectivePrimary,
      textTheme: _textTheme(base.textTheme, effectiveFont),
      splashColor: effectivePrimary.withValues(alpha: 0.12),
      highlightColor: Colors.transparent,
      dividerColor: AppColors.stroke,
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        systemOverlayStyle: SystemUiOverlayStyle.light,
        iconTheme: const IconThemeData(color: AppColors.textPrimary),
        titleTextStyle: _font(effectiveFont,
            size: 18, weight: FontWeight.w600, color: AppColors.textPrimary),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surface,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        hintStyle: const TextStyle(color: AppColors.textMuted, fontSize: 14),
        labelStyle: const TextStyle(color: AppColors.textSecondary),
        prefixIconColor: AppColors.textMuted,
        suffixIconColor: AppColors.textMuted,
        border: _inputBorder(AppColors.stroke),
        enabledBorder: _inputBorder(AppColors.stroke),
        focusedBorder: _inputBorder(AppColors.primary),
        errorBorder: _inputBorder(AppColors.danger),
        focusedErrorBorder: _inputBorder(AppColors.danger),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: AppColors.bgElevated,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
      ),
      dialogTheme: const DialogThemeData(
        backgroundColor: AppColors.bgElevated,
        surfaceTintColor: Colors.transparent,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.surfaceAlt,
        contentTextStyle: _font(effectiveFont, size: 14, weight: FontWeight.w400, color: AppColors.textPrimary),
      ),
      chipTheme: base.chipTheme.copyWith(
        backgroundColor: AppColors.surface,
        labelStyle: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
        side: const BorderSide(color: AppColors.stroke),
        shape: const StadiumBorder(),
      ),
    );
  }

  static OutlineInputBorder _inputBorder(Color color) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: color, width: 1.2),
      );

  /// 'Poppins' always uses the bundled asset (no network round-trip for the
  /// default look); any other family name is fetched live via google_fonts,
  /// which is how an admin-chosen font actually takes effect on screens
  /// that read from the ambient theme.
  static TextStyle _font(
    String font, {
    required double size,
    required FontWeight weight,
    double? height,
    Color? color,
    double? spacing,
  }) {
    final style = TextStyle(
      fontSize: size,
      fontWeight: weight,
      height: height,
      letterSpacing: spacing,
      color: color ?? AppColors.textPrimary,
    );
    if (font == fontFamily) return style.copyWith(fontFamily: font);
    return GoogleFonts.getFont(font, textStyle: style);
  }

  static TextTheme _textTheme(TextTheme base, String font) {
    return base.copyWith(
      displaySmall: _font(font, size: 30, weight: FontWeight.w700, height: 1.15),
      headlineMedium: _font(font, size: 26, weight: FontWeight.w700, height: 1.15),
      headlineSmall: _font(font, size: 22, weight: FontWeight.w600, height: 1.2),
      titleLarge: _font(font, size: 19, weight: FontWeight.w600),
      titleMedium: _font(font, size: 16, weight: FontWeight.w600),
      titleSmall: _font(font, size: 14, weight: FontWeight.w600),
      bodyLarge: _font(font, size: 15, weight: FontWeight.w400, height: 1.4, color: AppColors.textSecondary),
      bodyMedium: _font(font, size: 14, weight: FontWeight.w400, height: 1.4, color: AppColors.textSecondary),
      bodySmall: _font(font, size: 12, weight: FontWeight.w400, height: 1.4, color: AppColors.textMuted),
      labelLarge: _font(font, size: 14, weight: FontWeight.w600),
      labelMedium: _font(font, size: 12, weight: FontWeight.w500, color: AppColors.textSecondary),
    );
  }
}
