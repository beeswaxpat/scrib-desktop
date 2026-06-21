import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrib_desktop/constants.dart';

/// Invariants over the top-level constants. These guard the contracts the rest
/// of the app (and the .scrb format) silently depend on.
void main() {
  test('appName is Scrib and appVersion is non-empty', () {
    expect(appName, 'Scrib');
    expect(appVersion, isNotEmpty);
  });

  test('appVersion is a prefix of the pubspec version (drift guard)', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final match = RegExp(r'^version:\s*([0-9]+\.[0-9]+\.[0-9]+)', multiLine: true)
        .firstMatch(pubspec);
    expect(match, isNotNull, reason: 'pubspec.yaml must declare a version');
    expect(match!.group(1), appVersion,
        reason: 'constants.appVersion must match pubspec version');
  });

  test('scrbMagic spells SCRB in ASCII', () {
    expect(scrbMagic, [0x53, 0x43, 0x52, 0x42]);
    expect(String.fromCharCodes(scrbMagic), 'SCRB');
  });

  test('current write version is v3 and v2 is still a distinct legacy version', () {
    expect(scrbCurrentVersion, scrbVersionV3);
    expect(scrbVersionV3, 0x03);
    expect(scrbVersionV2, 0x02);
    expect(scrbVersionV3, isNot(scrbVersionV2));
  });

  test('v2 PBKDF2 iteration count is frozen at 100000 (do not change)', () {
    expect(scrbPbkdf2Iterations, 100000);
  });

  test('key material length equals enc(32) + mac(32)', () {
    expect(scrbKeyMaterialLength, 64);
    expect(scrbKeyMaterialLength, 32 + 32);
  });

  test('IV is the AES block size and HMAC is SHA-256 width', () {
    expect(scrbIvLength, 16);
    expect(scrbHmacLength, 32);
    expect(scrbSaltLength, 32);
  });

  test('v3 default iterations sit within the validated bounds', () {
    expect(scrbV3DefaultIterations, greaterThanOrEqualTo(scrbMinIterations));
    expect(scrbV3DefaultIterations, lessThanOrEqualTo(scrbMaxIterations));
    expect(scrbKdfPbkdf2Sha256, 0x01);
  });

  test('font-size ordering invariants hold', () {
    expect(minFontSize, lessThan(defaultFontSize));
    expect(defaultFontSize, lessThan(maxFontSize));
    expect(customFontSizeMin, lessThanOrEqualTo(minFontSize));
    expect(customFontSizeMax, greaterThanOrEqualTo(maxFontSize));
  });

  test('color palettes have the documented sizes', () {
    expect(noteColors.length, 16);
    expect(accentColors.length, 5);
  });

  test('every color palette has a matching name array', () {
    expect(textPaletteColors.length, textPaletteNames.length);
    expect(neonHighlightColors.length, neonHighlightNames.length);
    expect(accentColorNames.length, accentColors.length);
  });

  test('systemFonts includes the defaults and fontSizes is strictly ascending', () {
    expect(systemFonts, contains('JetBrains Mono'));
    expect(systemFonts, contains('Calibri'));
    for (int i = 1; i < fontSizes.length; i++) {
      expect(fontSizes[i], greaterThan(fontSizes[i - 1]));
    }
  });

  test('scribRichPrefix is the exact rich-text envelope prefix', () {
    expect(scribRichPrefix, '{"scrib_rich":');
  });
}
