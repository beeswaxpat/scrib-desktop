import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

/// Drift guards over the claims the contributor-facing docs make about the
/// code. Each of these was false at some point: ARCHITECTURE.md said every
/// write funnelled through two functions while seven sites bypassed them,
/// three documents said flutter_quill was pinned at 11.5.0 while pubspec.yaml
/// declared a caret range, and CLAUDE.md called the Hive settings box
/// encrypted when it is opened with no cipher and holds note file paths.
void main() {
  String read(String path) => File(path).readAsStringSync();

  test('flutter_quill is pinned exactly, matching what the docs claim', () {
    final pubspec = read('pubspec.yaml');
    final match =
        RegExp(r'^\s*flutter_quill:\s*(\S+)', multiLine: true).firstMatch(pubspec);
    expect(match, isNotNull, reason: 'pubspec.yaml must declare flutter_quill');
    expect(match!.group(1), '11.5.0',
        reason: 'ARCHITECTURE.md invariant 5 and CONTRIBUTING.md state an exact '
            'pin; a range puts the version back in the lockfile only');
    expect(read('ARCHITECTURE.md'), contains('11.5.0'));
    expect(read('CONTRIBUTING.md'), contains('11.5.0'));
  });

  test('ARCHITECTURE.md does not claim a single funnel for writes', () {
    final arch = read('ARCHITECTURE.md');
    expect(arch, isNot(contains('All writes funnel into two functions')));
    // The writers the routing section has to account for.
    for (final writer in [
      '_saveTabToDisk',
      'saveActiveTabAs',
      'changeActivePassword',
      'markTabSavedAs',
    ]) {
      expect(arch, contains(writer),
          reason: 'the save-path routing section must name every writer');
    }
  });

  test('CLAUDE.md does not describe the Hive settings box as encrypted', () {
    expect(read('CLAUDE.md'), isNot(contains('Hive encrypted')));
  });
}
