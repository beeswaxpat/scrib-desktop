import 'package:flutter/material.dart';

/// Scrib brand constants
const String appName = 'Scrib';
const String appVersion = '1.1.0';
const String appTagline = 'No tracking. No cloud. Just notes.';

/// .scrb file format magic bytes
const List<int> scrbMagic = [0x53, 0x43, 0x52, 0x42]; // "SCRB"
const int scrbVersionV1 = 0x01; // Legacy: AES-256-CBC, no HMAC, 10k PBKDF2
const int scrbVersionV2 = 0x02; // Current: AES-256-CBC + HMAC-SHA256 (Encrypt-then-MAC), 100k PBKDF2
const int scrbCurrentVersion = scrbVersionV2;

/// Note colors palette - 16 research-backed colors (shared with mobile)
const List<Color> noteColors = [
  Color(0xFFFF7F50), // Coral Red
  Color(0xFFFFDAB9), // Peach
  Color(0xFFFFD700), // Gold
  Color(0xFFB5E7A0), // Mint Green
  Color(0xFF50C878), // Emerald Green
  Color(0xFF008080), // Deep Teal
  Color(0xFF0EA5E9), // Electric Blue
  Color(0xFFA7C7E7), // Soft Blue
  Color(0xFFD7BDE2), // Lavender
  Color(0xFFDA70D6), // Orchid Pink
  Color(0xFFF5F5F5), // Off-White
  Color(0xFFD3D3D3), // Light Gray
  Color(0xFF808080), // Mid Gray
  Color(0xFF2F4F4F), // Dark Slate
  Color(0xFF4A5568), // Slate Gray
  Color(0xFF6B7280), // Cool Gray
];

/// Accent colors (same 5 as mobile Scrib)
const List<Color> accentColors = [
  Color(0xFF008080), // Teal
  Color(0xFF0EA5E9), // Blue
  Color(0xFF7C3AED), // Purple
  Color(0xFFEF4444), // Crimson
  Color(0xFFFF9800), // Orange
];

/// Text color palette for rich text formatting
const List<Color> textPaletteColors = [
  Color(0xFFEF4444), // Red
  Color(0xFFF97316), // Orange
  Color(0xFFEAB308), // Yellow
  Color(0xFF22C55E), // Green
  Color(0xFF14B8A6), // Teal
  Color(0xFF3B82F6), // Blue
  Color(0xFF8B5CF6), // Purple
  Color(0xFFEC4899), // Pink
  Color(0xFFFFFFFF), // White
  Color(0xFF6B7280), // Gray
];

const List<String> textPaletteNames = [
  'Red', 'Orange', 'Yellow', 'Green', 'Teal',
  'Blue', 'Purple', 'Pink', 'White', 'Gray',
];

/// Neon highlight colors - Scrib's unique glow-style highlights (Blade Runner aesthetic)
const List<Color> neonHighlightColors = [
  Color(0xFF1A5555), // Cyber Teal
  Color(0xFF551A42), // Neon Rose
  Color(0xFF1A5528), // Matrix Green
  Color(0xFF55551A), // Electric Gold
  Color(0xFF55401A), // Amber Glow
  Color(0xFF401A55), // Ultra Violet
  Color(0xFF1A3555), // Deep Blue
  Color(0xFF551A1A), // Crimson Pulse
];

const List<String> neonHighlightNames = [
  'Cyber Teal', 'Neon Rose', 'Matrix Green', 'Electric Gold',
  'Amber Glow', 'Ultra Violet', 'Deep Blue', 'Crimson Pulse',
];

/// Common Windows system fonts for the font picker
const List<String> systemFonts = [
  'Segoe UI',
  'Arial',
  'Calibri',
  'Cambria',
  'Consolas',
  'Courier New',
  'Georgia',
  'Impact',
  'JetBrains Mono',
  'Lucida Console',
  'Tahoma',
  'Times New Roman',
  'Trebuchet MS',
  'Verdana',
];

/// Common font sizes for the rich text size picker
const List<int> fontSizes = [
  8, 9, 10, 11, 12, 14, 16, 18, 20, 22, 24, 28, 32, 36, 48, 72,
];

/// Prefix for detecting rich text content inside .scrb files
const String scribRichPrefix = '{"scrib_rich":';
