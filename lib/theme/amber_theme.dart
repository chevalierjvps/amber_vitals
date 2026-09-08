import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Amberglow palette — same colors as the desktop rice, but applied to a
/// clean modern Material 3 layout instead of the full retro-CRT chrome.
/// The "retro touch" here is just the monospace numerals on live readings
/// and the phosphor glow on the accent color, not scanlines/borders.
class AmberPalette {
  static const background = Color(0xFF1A150F);
  static const surface = Color(0xFF241D15);
  static const surfaceHigh = Color(0xFF2F261A);
  static const border = Color(0xFF4A3F30);
  static const amber = Color(0xFFE8952D);
  static const amberBright = Color(0xFFF2A94A);
  static const green = Color(0xFF9DBB5C);
  static const red = Color(0xFFD9483D);
  static const cream = Color(0xFFD8C48A);
  static const text = Color(0xFFE0D4B0);
  static const textDim = Color(0xFF8A7D63);
}

class AmberTheme {
  static ThemeData build() {
    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: const ColorScheme.dark(
        primary: AmberPalette.amber,
        onPrimary: AmberPalette.background,
        secondary: AmberPalette.green,
        onSecondary: AmberPalette.background,
        error: AmberPalette.red,
        surface: AmberPalette.surface,
        onSurface: AmberPalette.text,
      ),
      scaffoldBackgroundColor: AmberPalette.background,
      fontFamily: GoogleFonts.inter().fontFamily,
    );

    return base.copyWith(
      textTheme: GoogleFonts.interTextTheme(base.textTheme).apply(
        bodyColor: AmberPalette.text,
        displayColor: AmberPalette.text,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: AmberPalette.background,
        foregroundColor: AmberPalette.text,
        elevation: 0,
        centerTitle: false,
      ),
      cardTheme: CardThemeData(
        color: AmberPalette.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AmberPalette.border),
        ),
        margin: EdgeInsets.zero,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AmberPalette.amber,
          foregroundColor: AmberPalette.background,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AmberPalette.text,
          side: const BorderSide(color: AmberPalette.border),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AmberPalette.surfaceHigh,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AmberPalette.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AmberPalette.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AmberPalette.amber, width: 1.5),
        ),
      ),
      dividerTheme: const DividerThemeData(color: AmberPalette.border),
    );
  }

  /// Monospace text style for live numeric readouts (BPM, SpO2, etc) — the
  /// one deliberate "retro" accent kept in an otherwise modern UI.
  static TextStyle readoutStyle({double size = 40, Color? color}) {
    return GoogleFonts.jetBrainsMono(
      fontSize: size,
      fontWeight: FontWeight.w700,
      color: color ?? AmberPalette.amber,
      shadows: [
        Shadow(
          color: (color ?? AmberPalette.amber).withValues(alpha: 0.5),
          blurRadius: 12,
        ),
      ],
    );
  }
}
