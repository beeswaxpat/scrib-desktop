import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

/// Guards over the build and release pipeline. The 2026-07-25 review found the
/// release workflow published an unsigned zip whose only integrity statement
/// was a checksum the publishing job computed from that same zip, with every
/// third-party action referenced by a mutable major tag (the tj-actions
/// retag class of attack) under a workflow-wide contents: write token. These
/// tests fail if any of that comes back.
void main() {
  final flutterCi = File('.github/workflows/flutter.yml').readAsStringSync();
  final release = File('.github/workflows/release.yml').readAsStringSync();

  final usesLine = RegExp(r'^.*\buses:\s*(\S+)(.*)$', multiLine: true);
  final shaPin = RegExp(r'^[\w.\-]+/[\w.\-]+@[0-9a-f]{40}$');

  for (final entry in {'flutter.yml': flutterCi, 'release.yml': release}.entries) {
    test('${entry.key}: every action is pinned to a full commit SHA', () {
      final matches = usesLine.allMatches(entry.value).toList();
      expect(matches, isNotEmpty, reason: 'workflow must reference actions');
      for (final m in matches) {
        final ref = m.group(1)!;
        final trailing = m.group(2)!;
        expect(shaPin.hasMatch(ref), isTrue,
            reason: '$ref must be pinned to a 40-character commit SHA, '
                'not a mutable tag');
        expect(RegExp(r'#\s*v\d').hasMatch(trailing), isTrue,
            reason: '$ref needs a trailing version comment so the pin is '
                'readable and Dependabot can bump it');
      }
    });
  }

  test('release.yml grants contents: write to the publishing job only', () {
    final jobsAt = release.indexOf('\njobs:');
    expect(jobsAt, greaterThan(0));

    final workflowScope = release.substring(0, jobsAt);
    expect(workflowScope.contains('contents: write'), isFalse,
        reason: 'workflow-scope write access hands a repo-writing token to '
            'every step, including third-party action code');
    expect(workflowScope.contains('contents: read'), isTrue,
        reason: 'declare the least-privilege default explicitly');

    expect('contents: write'.allMatches(release).length, 1,
        reason: 'exactly one job should be able to write to the repo');
    final publishAt = release.indexOf('\n  publish:');
    expect(publishAt, greaterThan(0), reason: 'publishing is its own job');
    expect(release.indexOf('contents: write'), greaterThan(publishAt),
        reason: 'the build job must not hold write access');
  });

  test('release.yml attests build provenance with the right permissions', () {
    expect(release.contains('actions/attest-build-provenance@'), isTrue,
        reason: 'the .sha256 only restates the zip; the attestation is the '
            'independent statement');
    expect(release.contains('id-token: write'), isTrue);
    expect(release.contains('attestations: write'), isTrue);
  });

  test('release.yml has a signing step that skips when no secret is set', () {
    expect(release.contains('AZURE_TRUSTED_SIGNING_ACCOUNT'), isTrue);
    expect(release.contains("steps.signing.outputs.configured == 'true'"), isTrue,
        reason: 'signing must be conditional so releases still publish '
            'before a certificate exists');
  });

  test('flutter.yml scans dependencies without gating the build', () {
    expect(flutterCi.contains('actions/dependency-review-action@'), isTrue);
    expect(flutterCi.contains('warn-only: true'), isTrue,
        reason: 'advisories are surfaced, not enforced');
    expect(flutterCi.contains('flutter pub outdated'), isTrue);
  });

  test('dependabot holds back only major flutter_quill bumps', () {
    final dependabot = File('.github/dependabot.yml').readAsStringSync();
    expect(dependabot.contains('dependency-name: flutter_quill'), isTrue);
    expect(dependabot.contains('version-update:semver-major'), isTrue,
        reason: 'a blanket ignore also suppressed 11.x security releases');
  });

  test('Runner.rc metadata names the publisher and the GPL', () {
    final rc = File('windows/runner/Runner.rc').readAsStringSync();
    expect(rc.contains('All rights reserved'), isFalse,
        reason: 'contradicts the GPLv3 grant the binary ships under');
    expect(rc.contains('VALUE "CompanyName", "Beeswax Pat"'), isTrue);
    expect(rc.contains('VALUE "ProductName", "Scrib Desktop"'), isTrue);
    expect(rc.contains('VALUE "FileDescription", "Scrib Desktop"'), isTrue);
    expect(RegExp(r'LegalCopyright".*GNU General Public License').hasMatch(rc),
        isTrue);
    // The build drives these, so they must stay macro-driven.
    expect(rc.contains('VALUE "FileVersion", VERSION_AS_STRING'), isTrue);
    expect(rc.contains('VALUE "ProductVersion", VERSION_AS_STRING'), isTrue);
  });

  test('the runner window is created with the product name', () {
    final mainCpp = File('windows/runner/main.cpp').readAsStringSync();
    expect(mainCpp.contains('window.Create(L"Scrib Desktop"'), isTrue,
        reason: 'the taskbar entry showed the snake_case internal name until '
            'window_manager set the real title');
  });
}
