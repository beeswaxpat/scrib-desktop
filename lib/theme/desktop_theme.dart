import 'package:flutter/material.dart';
import '../constants.dart';

/// Scrib Desktop theme - dark Blade Runner aesthetic with Scrib brand colors
class ScribTheme {
  static ThemeData darkTheme({int accentColorIndex = 0}) {
    final seedColor = accentColors[accentColorIndex.clamp(0, accentColors.length - 1)];

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorSchemeSeed: seedColor,
      scaffoldBackgroundColor: const Color(0xFF0D0D0D),
      fontFamily: 'Segoe UI',
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF141414),
        foregroundColor: Color(0xFFE0E0E0),
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      cardTheme: const CardThemeData(
        color: Color(0xFF1A1A1A),
        elevation: 0,
      ),
      dividerTheme: const DividerThemeData(
        color: Color(0xFF2A2A2A),
        thickness: 1,
      ),
      menuBarTheme: const MenuBarThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(Color(0xFF141414)),
        ),
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor: const WidgetStatePropertyAll(Color(0xFF1E1E1E)),
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
      textTheme: const TextTheme(
        bodyLarge: TextStyle(color: Color(0xFFE0E0E0), height: 1.6),
        bodyMedium: TextStyle(color: Color(0xFFB0B0B0)),
        bodySmall: TextStyle(color: Color(0xFF808080)),
        titleLarge: TextStyle(color: Color(0xFFE0E0E0), fontWeight: FontWeight.w600),
        titleMedium: TextStyle(color: Color(0xFFE0E0E0)),
        labelSmall: TextStyle(color: Color(0xFF808080), fontSize: 11),
      ),
    );
  }

  static ThemeData lightTheme({int accentColorIndex = 0}) {
    final seedColor = accentColors[accentColorIndex.clamp(0, accentColors.length - 1)];

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorSchemeSeed: seedColor,
      scaffoldBackgroundColor: const Color(0xFFFAFAFA),
      fontFamily: 'Segoe UI',
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFFFFFFFF),
        foregroundColor: Color(0xFF1A1A1A),
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      cardTheme: const CardThemeData(
        color: Color(0xFFFFFFFF),
        elevation: 0,
      ),
      dividerTheme: const DividerThemeData(
        color: Color(0xFFE0E0E0),
        thickness: 1,
      ),
      menuBarTheme: const MenuBarThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(Color(0xFFF5F5F5)),
        ),
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor: const WidgetStatePropertyAll(Color(0xFFFFFFFF)),
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
      textTheme: const TextTheme(
        bodyLarge: TextStyle(color: Color(0xFF1A1A1A), height: 1.6),
        bodyMedium: TextStyle(color: Color(0xFF444444)),
        bodySmall: TextStyle(color: Color(0xFF666666)),
        titleLarge: TextStyle(color: Color(0xFF1A1A1A), fontWeight: FontWeight.w600),
        titleMedium: TextStyle(color: Color(0xFF1A1A1A)),
        labelSmall: TextStyle(color: Color(0xFF666666), fontSize: 11),
      ),
    );
  }
}
