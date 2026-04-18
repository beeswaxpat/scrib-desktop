import 'package:flutter/material.dart';
import '../constants.dart';
import 'scrib_colors.dart';

/// Scrib Desktop theme - dark Blade Runner aesthetic with Scrib brand colors.
///
/// Both [darkTheme] and [lightTheme] are memoized by accent color index so
/// they don't allocate a fresh ThemeData on every editor-state change.
/// For a typing-heavy app this matters — see main.dart _onEditorChanged.
class ScribTheme {
  static final Map<int, ThemeData> _darkCache = {};
  static final Map<int, ThemeData> _lightCache = {};

  static ThemeData darkTheme({int accentColorIndex = 0}) {
    final idx = accentColorIndex.clamp(0, accentColors.length - 1);
    return _darkCache.putIfAbsent(idx, () => _buildDark(idx));
  }

  static ThemeData lightTheme({int accentColorIndex = 0}) {
    final idx = accentColorIndex.clamp(0, accentColors.length - 1);
    return _lightCache.putIfAbsent(idx, () => _buildLight(idx));
  }

  static ThemeData _buildDark(int idx) {
    final seedColor = accentColors[idx];
    const colors = ScribColors.dark;

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorSchemeSeed: seedColor,
      scaffoldBackgroundColor: colors.surface,
      fontFamily: 'Segoe UI',
      extensions: const [colors],
      appBarTheme: AppBarTheme(
        backgroundColor: colors.surfaceChrome,
        foregroundColor: colors.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      cardTheme: CardThemeData(
        color: colors.surfaceAccent,
        elevation: 0,
      ),
      dividerTheme: DividerThemeData(
        color: colors.border,
        thickness: 1,
      ),
      menuBarTheme: MenuBarThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(colors.surfaceChrome),
        ),
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(colors.surfaceElevated),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
      ),
      menuButtonTheme: MenuButtonThemeData(
        style: ButtonStyle(
          textStyle: const WidgetStatePropertyAll(TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w400,
            letterSpacing: 0.1,
          )),
          minimumSize: const WidgetStatePropertyAll(Size(0, 32)),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 12, vertical: 0),
          ),
        ),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        border: InputBorder.none,
        focusedBorder: InputBorder.none,
      ),
      textTheme: TextTheme(
        bodyLarge: TextStyle(color: colors.textPrimary, height: editorLineHeight),
        bodyMedium: TextStyle(color: colors.textSecondary),
        bodySmall: TextStyle(color: colors.textMuted),
        titleLarge: TextStyle(color: colors.textPrimary, fontWeight: FontWeight.w600),
        titleMedium: TextStyle(color: colors.textPrimary),
        labelSmall: TextStyle(color: colors.textMuted, fontSize: 11),
      ),
    );
  }

  static ThemeData _buildLight(int idx) {
    final seedColor = accentColors[idx];
    const colors = ScribColors.light;

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorSchemeSeed: seedColor,
      scaffoldBackgroundColor: const Color(0xFFFAFAFA),
      fontFamily: 'Segoe UI',
      extensions: const [colors],
      appBarTheme: AppBarTheme(
        backgroundColor: colors.surfaceElevated,
        foregroundColor: colors.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      cardTheme: CardThemeData(
        color: colors.surfaceElevated,
        elevation: 0,
      ),
      dividerTheme: DividerThemeData(
        color: colors.border,
        thickness: 1,
      ),
      menuBarTheme: MenuBarThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(colors.surfaceAccent),
        ),
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(colors.surfaceElevated),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
      ),
      menuButtonTheme: MenuButtonThemeData(
        style: ButtonStyle(
          textStyle: const WidgetStatePropertyAll(TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w400,
            letterSpacing: 0.1,
          )),
          minimumSize: const WidgetStatePropertyAll(Size(0, 32)),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 12, vertical: 0),
          ),
        ),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        border: InputBorder.none,
        focusedBorder: InputBorder.none,
      ),
      textTheme: TextTheme(
        bodyLarge: TextStyle(color: colors.textPrimary, height: editorLineHeight),
        bodyMedium: const TextStyle(color: Color(0xFF444444)),
        bodySmall: TextStyle(color: colors.textMuted),
        titleLarge: TextStyle(color: colors.textPrimary, fontWeight: FontWeight.w600),
        titleMedium: TextStyle(color: colors.textPrimary),
        labelSmall: TextStyle(color: colors.textMuted, fontSize: 11),
      ),
    );
  }
}
