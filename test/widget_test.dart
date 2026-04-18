import 'package:flutter_test/flutter_test.dart';
import 'package:scrib_desktop/constants.dart';

/// Smoke test for top-level constants. Full widget integration tests require
/// window_manager / path_provider mocking which doesn't run cleanly in the
/// default Flutter test harness — see file_service_test.dart,
/// rtf_service_test.dart, atomic_write_test.dart, and
/// editor_provider_test.dart for the real coverage.
void main() {
  test('version constants are consistent', () {
    expect(appVersion, isNotEmpty);
    expect(appName, 'Scrib');
    expect(scrbMagic, [0x53, 0x43, 0x52, 0x42]);
    expect(scrbCurrentVersion, scrbVersionV2);
  });

  test('crypto parameters match documented security model', () {
    // DO NOT CHANGE without bumping scrbCurrentVersion. Existing .scrb files
    // on users' disks depend on these exact values.
    expect(scrbPbkdf2Iterations, 100000);
    expect(scrbKeyMaterialLength, 64);
    expect(scrbIvLength, 16);
    expect(scrbSaltLength, 32);
    expect(scrbHmacLength, 32);
  });

  test('color palettes have matching name arrays', () {
    expect(textPaletteColors.length, textPaletteNames.length);
    expect(neonHighlightColors.length, neonHighlightNames.length);
  });

  test('accent colors list has 5 entries (matches mobile)', () {
    expect(accentColors.length, 5);
  });
}
