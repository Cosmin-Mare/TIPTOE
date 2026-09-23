import 'package:flutter/material.dart';

class TiptoeColors {
  static const ink = Color(0xFF101418);
  static const card = Color(0xFF1A2129);
  static const line = Color(0xFF2C3642);
  static const amber = Color(0xFFE4B15A);
  static const mist = Color(0xFFE8E2D6);
  static const mute = Color(0xFF93A0AD);
  static const ok = Color(0xFF7DCEA0);
  static const warn = Color(0xFFE0A15A);
  static const bad = Color(0xFFE07A6A);
}

ThemeData tiptoeTheme() {
  final base = ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,
    scaffoldBackgroundColor: TiptoeColors.ink,
    colorScheme: const ColorScheme.dark(
      surface: TiptoeColors.ink,
      primary: TiptoeColors.amber,
      onPrimary: Color(0xFF1A1408),
      secondary: TiptoeColors.mist,
      error: TiptoeColors.bad,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: TiptoeColors.ink,
      foregroundColor: TiptoeColors.mist,
      elevation: 0,
      centerTitle: false,
    ),
    cardTheme: CardThemeData(
      color: TiptoeColors.card,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: TiptoeColors.line),
      ),
    ),
    dividerColor: TiptoeColors.line,
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(bodyColor: TiptoeColors.mist, displayColor: TiptoeColors.mist),
  );
}
