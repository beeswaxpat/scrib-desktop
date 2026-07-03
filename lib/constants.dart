import 'package:flutter/material.dart';

/// Scrib brand constants
const String appName = 'Scrib';
const String appVersion = '1.7.0';
const String appTagline = 'No tracking. No cloud. Just notes.';

/// .scrb file format magic bytes
const List<int> scrbMagic = [0x53, 0x43, 0x52, 0x42]; // "SCRB"

/// v2: AES-256-CBC + HMAC-SHA256 (Encrypt-then-MAC), PBKDF2-SHA256 100k.
/// Header is fixed-width with NO parameter block — the iteration count is the
/// compile-time constant [scrbPbkdf2Iterations]. Kept forever for reading the
/// files every 1.1.x / 1.2.0 build already wrote to users' disks.
const int scrbVersionV2 = 0x02;

/// v3: same primitives (AES-256-CBC + HMAC-SHA256, Encrypt-then-MAC) but the
/// KDF parameters are stored *in the header* and authenticated by the HMAC, so
/// the work factor is self-describing and can be raised per-file over time
/// without ever breaking older files. New saves use v3; v2 files still decrypt
/// via the preserved v2 branch.
///
/// v3 layout: [SCRB 4B][ver 1B][kdfId 1B][iterations uint32 BE 4B]
///            [IV 16B][salt 32B][HMAC 32B][ciphertext]
/// The HMAC authenticates ver ‖ kdfId ‖ iterations ‖ IV ‖ salt ‖ ciphertext,
/// so a downgrade of the stored iteration count fails the MAC check before any
/// key derivation is trusted.
const int scrbVersionV3 = 0x03;

/// The version new saves are written as.
const int scrbCurrentVersion = scrbVersionV3;

/// KDF identifiers stored in the v3 `kdfId` byte. Leaves room for a future
/// memory-hard KDF (e.g. Argon2id = 0x02) without another format version.
const int scrbKdfPbkdf2Sha256 = 0x01;

/// Crypto parameters — DO NOT CHANGE without bumping scrbCurrentVersion.
/// These values are baked into existing .scrb files on users' disks.
///
/// [scrbPbkdf2Iterations] is the FROZEN v2 iteration count: v2 files store no
/// parameters, so their key derivation depends on this exact value. Do not
/// change it. New (v3) files instead store their own iteration count in the
/// header and default to [scrbV3DefaultIterations].
const int scrbPbkdf2Iterations = 100000;

/// Default PBKDF2-SHA256 iterations for new v3 files.
///
/// Held at 100k for now — NOT raised to OWASP's 600k — for a concrete reason:
/// the key is re-derived on every save (each save uses a fresh salt) and on
/// every auto-save tick, and pure-Dart PBKDF2 costs ~0.85s at 100k / ~5s at
/// 600k on typical hardware. A real cost increase needs per-session key
/// caching (derive once per open, reuse a stable per-file salt across saves)
/// first; that is a separate change. The win v3 banks now is that this count
/// is STORED IN AND AUTHENTICATED BY each file, so raising it later is a
/// one-line change that breaks no existing file and needs no new format
/// version. Stored as a big-endian uint32 in the v3 header.
const int scrbV3DefaultIterations = 100000;

/// Defensive bounds on the iteration count parsed from an untrusted v3 header.
/// Anything outside this range is rejected before key derivation.
const int scrbMinIterations = 1;
const int scrbMaxIterations = 100000000;

const int scrbKeyMaterialLength = 64; // 32 bytes enc + 32 bytes mac
const int scrbIvLength = 16;          // AES block size
const int scrbSaltLength = 32;        // PBKDF2 salt
const int scrbHmacLength = 32;        // SHA-256 output

/// UI constants extracted from widgets for consistency
const double editorLineHeight = 1.6;
const double defaultFontSize = 14.0;
const double minFontSize = 8.0;
const double maxFontSize = 48.0;
const double customFontSizeMin = 6.0;
const double customFontSizeMax = 144.0;
const double accentBorderAlpha = 0.45;
const double editorContentPadding = 16.0;

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

/// Human-readable names for [accentColors] — used for accessibility labels.
const List<String> accentColorNames = [
  'Teal', 'Blue', 'Purple', 'Crimson', 'Orange',
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
