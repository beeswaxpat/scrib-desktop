import 'package:flutter/material.dart';

/// Centralized surface / text colors used across Scrib widgets.
///
/// Historically these were `const Color(0xFF0D0D0D)` hex literals scattered
/// through ~10 widgets. Pulling them into a theme extension keeps the
/// Blade Runner dark palette coherent and makes future light-theme tweaks
/// a single-file change.
@immutable
class ScribColors extends ThemeExtension<ScribColors> {
  /// Scaffold / editor background
  final Color surface;
  /// Menu bar, tab bar, toolbar, status bar background
  final Color surfaceChrome;
  /// Popup menu, card, elevated surface background
  final Color surfaceElevated;
  /// Hovered / active tab background
  final Color surfaceAccent;
  /// Divider / border color
  final Color border;
  /// Primary text (body copy in editor, labels)
  final Color textPrimary;
  /// Secondary text (button labels, status items)
  final Color textSecondary;
  /// Tertiary text (hints, muted metadata)
  final Color textMuted;
  /// Disabled state for buttons and text
  final Color textDisabled;
  /// Gold lock icon (encryption indicator)
  final Color encryptionLock;

  const ScribColors({
    required this.surface,
    required this.surfaceChrome,
    required this.surfaceElevated,
    required this.surfaceAccent,
    required this.border,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    required this.textDisabled,
    required this.encryptionLock,
  });

  static const dark = ScribColors(
    surface: Color(0xFF0D0D0D),
    surfaceChrome: Color(0xFF141414),
    surfaceElevated: Color(0xFF1E1E1E),
    surfaceAccent: Color(0xFF1A1A1A),
    border: Color(0xFF2A2A2A),
    textPrimary: Color(0xFFE0E0E0),
    textSecondary: Color(0xFFB0B0B0),
    textMuted: Color(0xFF808080),
    textDisabled: Color(0xFF404040),
    encryptionLock: Color(0xFFFBBF24),
  );

  static const light = ScribColors(
    surface: Color(0xFFFFFFFF),
    surfaceChrome: Color(0xFFF0F0F0),
    surfaceElevated: Color(0xFFFFFFFF),
    surfaceAccent: Color(0xFFF5F5F5),
    border: Color(0xFFE0E0E0),
    textPrimary: Color(0xFF1A1A1A),
    textSecondary: Color(0xFF555555),
    textMuted: Color(0xFF666666),
    textDisabled: Color(0xFFCCCCCC),
    encryptionLock: Color(0xFFFBBF24),
  );

  @override
  ScribColors copyWith({
    Color? surface,
    Color? surfaceChrome,
    Color? surfaceElevated,
    Color? surfaceAccent,
    Color? border,
    Color? textPrimary,
    Color? textSecondary,
    Color? textMuted,
    Color? textDisabled,
    Color? encryptionLock,
  }) =>
      ScribColors(
        surface: surface ?? this.surface,
        surfaceChrome: surfaceChrome ?? this.surfaceChrome,
        surfaceElevated: surfaceElevated ?? this.surfaceElevated,
        surfaceAccent: surfaceAccent ?? this.surfaceAccent,
        border: border ?? this.border,
        textPrimary: textPrimary ?? this.textPrimary,
        textSecondary: textSecondary ?? this.textSecondary,
        textMuted: textMuted ?? this.textMuted,
        textDisabled: textDisabled ?? this.textDisabled,
        encryptionLock: encryptionLock ?? this.encryptionLock,
      );

  @override
  ScribColors lerp(ThemeExtension<ScribColors>? other, double t) {
    if (other is! ScribColors) return this;
    return ScribColors(
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceChrome: Color.lerp(surfaceChrome, other.surfaceChrome, t)!,
      surfaceElevated: Color.lerp(surfaceElevated, other.surfaceElevated, t)!,
      surfaceAccent: Color.lerp(surfaceAccent, other.surfaceAccent, t)!,
      border: Color.lerp(border, other.border, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textMuted: Color.lerp(textMuted, other.textMuted, t)!,
      textDisabled: Color.lerp(textDisabled, other.textDisabled, t)!,
      encryptionLock: Color.lerp(encryptionLock, other.encryptionLock, t)!,
    );
  }
}

extension ScribColorsContext on BuildContext {
  ScribColors get scribColors =>
      Theme.of(this).extension<ScribColors>() ?? ScribColors.dark;
}
