import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrib_desktop/services/atomic_write.dart';

/// Tests the atomic-write helper. Critical properties: writes over existing
/// files succeed and leave no staging files behind; crash recovery only ever
/// touches Scrib's own namespaced temp/backup files, never unrelated user
/// files that merely end in `.tmp` or `.bak`.
void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('scrib_atomic_');
  });

  tearDown(() async {
    AtomicWrite.debugForceFallback = false; // never leak the seam between tests
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  String p(String name) => '${tmp.path}${Platform.pathSeparator}$name';

  group('writeBytes / writeString', () {
    test('writeBytes creates a new file with exact bytes', () async {
      final path = p('new.bin');
      final bytes = Uint8List.fromList([1, 2, 3, 4, 5]);
      await AtomicWrite.writeBytes(path, bytes);
      expect(await File(path).readAsBytes(), bytes);
    });

    test('writeBytes overwrites an existing file', () async {
      final path = p('existing.bin');
      await File(path).writeAsBytes([9, 9, 9]);
      await AtomicWrite.writeBytes(path, Uint8List.fromList([1, 2, 3]));
      expect(await File(path).readAsBytes(), [1, 2, 3]);
    });

    test('writeString round-trips', () async {
      final path = p('note.txt');
      await AtomicWrite.writeString(path, 'hello world');
      expect(await File(path).readAsString(), 'hello world');
    });

    test('no namespaced .scrib-tmp file remains after a successful write', () async {
      final path = p('clean.bin');
      await AtomicWrite.writeBytes(path, Uint8List.fromList([1]));
      expect(await File('$path${AtomicWrite.tmpSuffix}').exists(), isFalse);
    });

    test('writing into a non-existent directory throws and leaves no temp', () async {
      final path = '${tmp.path}${Platform.pathSeparator}nope${Platform.pathSeparator}f.bin';
      await expectLater(
        AtomicWrite.writeBytes(path, Uint8List.fromList([1])),
        throwsA(anything),
      );
      expect(await File('$path${AtomicWrite.tmpSuffix}').exists(), isFalse);
    });

    test('empty payload produces a zero-length file', () async {
      final path = p('empty.bin');
      await AtomicWrite.writeBytes(path, Uint8List(0));
      expect(await File(path).length(), 0);
    });

    test('large payload (5MB) round-trips', () async {
      final path = p('big.bin');
      final bytes = Uint8List(5 * 1024 * 1024);
      for (int i = 0; i < bytes.length; i += 4096) {
        bytes[i] = i % 256;
      }
      await AtomicWrite.writeBytes(path, bytes);
      expect(await File(path).length(), bytes.length);
    });

    test('two rapid sequential writes leave the last content', () async {
      final path = p('seq.txt');
      await AtomicWrite.writeString(path, 'first');
      await AtomicWrite.writeString(path, 'second');
      expect(await File(path).readAsString(), 'second');
    });

    test('concurrent writes to the same path are serialized to one coherent result', () async {
      final path = p('race.txt');
      await Future.wait([
        AtomicWrite.writeString(path, 'AAAA'),
        AtomicWrite.writeString(path, 'BBBB'),
      ]);
      final result = await File(path).readAsString();
      expect(result == 'AAAA' || result == 'BBBB', isTrue,
          reason: 'content must be exactly one of the writes, not interleaved');
      expect(await File('$path${AtomicWrite.tmpSuffix}').exists(), isFalse);
    });

    test('concurrent writes via case-variant spellings of one file are '
        'serialized too', () async {
      final path = p('variant.txt');
      final upper = path.toUpperCase();
      await Future.wait([
        AtomicWrite.writeString(path, 'AAAA'),
        AtomicWrite.writeString(upper, 'BBBB'),
      ]);
      final result = await File(path).readAsString();
      expect(result == 'AAAA' || result == 'BBBB', isTrue,
          reason: 'case variants share one physical staging file, so their '
              'writes must share one lock');
      expect(await File('$path${AtomicWrite.tmpSuffix}').exists(), isFalse);
    }, skip: !Platform.isWindows
        ? 'case-insensitive paths are Windows behavior'
        : false);

    test('write onto a path occupied by a directory throws and deletes the '
        'staging file', () async {
      final path = p('dest-is-dir');
      await Directory(path).create();
      await expectLater(
        AtomicWrite.writeBytes(path, Uint8List.fromList([1, 2, 3])),
        throwsA(anything),
      );
      expect(await File('$path${AtomicWrite.tmpSuffix}').exists(), isFalse,
          reason: 'the rename-failure cleanup must remove the .scrib-tmp');
      expect(await Directory(path).exists(), isTrue);
    });
  });

  group('canonicalPath', () {
    test('normalizes case and separators on Windows', () {
      expect(canonicalPath('C:\\Notes\\A.txt'), canonicalPath('c:/notes/a.TXT'));
    }, skip: !Platform.isWindows
        ? 'case-insensitive paths are Windows behavior'
        : false);

    test('distinct files stay distinct', () {
      expect(canonicalPath(p('a.txt')), isNot(canonicalPath(p('b.txt'))));
    });
  });

  group('pure-Dart crash-safe fallback (forced)', () {
    setUp(() => AtomicWrite.debugForceFallback = true);

    test('fallback creates a new file', () async {
      final path = p('fb_new.bin');
      await AtomicWrite.writeBytes(path, Uint8List.fromList([7, 8, 9]));
      expect(await File(path).readAsBytes(), [7, 8, 9]);
    });

    test('fallback overwrites an existing file and leaves no .scrib-bak', () async {
      final path = p('fb_over.txt');
      await File(path).writeAsString('old');
      await AtomicWrite.writeString(path, 'new');
      expect(await File(path).readAsString(), 'new');
      expect(await File('$path${AtomicWrite.bakSuffix}').exists(), isFalse);
      expect(await File('$path${AtomicWrite.tmpSuffix}').exists(), isFalse);
    });

    test('fallback deletes a stale pre-existing backup and still succeeds', () async {
      final path = p('fb_stale.txt');
      await File(path).writeAsString('old');
      await File('$path${AtomicWrite.bakSuffix}').writeAsString('stale bak');
      await AtomicWrite.writeString(path, 'new');
      expect(await File(path).readAsString(), 'new');
      expect(await File('$path${AtomicWrite.bakSuffix}').exists(), isFalse);
    });

    test('fallback write leaves the original intact when the backup slot is '
        'blocked', () async {
      final path = p('fb_blocked.txt');
      await File(path).writeAsString('old');
      // A DIRECTORY at the backup path makes `target.rename(bak.path)` throw.
      await Directory('$path${AtomicWrite.bakSuffix}').create();

      await expectLater(
        AtomicWrite.writeString(path, 'new'),
        throwsA(anything),
      );
      expect(await File(path).readAsString(), 'old',
          reason: 'a failed fallback must never lose the previous content');
      expect(await File('$path${AtomicWrite.tmpSuffix}').exists(), isFalse,
          reason: 'the staging file must be cleaned up on failure');
    });
  });

  group('recoverIfNeeded', () {
    test('restores a namespaced backup when the primary is missing', () async {
      await File(p('note.txt${AtomicWrite.bakSuffix}')).writeAsString('recovered');
      await AtomicWrite.recoverIfNeeded(tmp.path);
      expect(await File(p('note.txt')).exists(), isTrue);
      expect(await File(p('note.txt')).readAsString(), 'recovered');
      expect(await File(p('note.txt${AtomicWrite.bakSuffix}')).exists(), isFalse);
    });

    test('deletes a stale namespaced backup when an intact primary exists', () async {
      await File(p('note.txt')).writeAsString('current');
      await File(p('note.txt${AtomicWrite.bakSuffix}')).writeAsString('stale');
      await AtomicWrite.recoverIfNeeded(tmp.path);
      expect(await File(p('note.txt')).readAsString(), 'current');
      expect(await File(p('note.txt${AtomicWrite.bakSuffix}')).exists(), isFalse);
    });

    test('keeps the backup when the primary is zero-length (suspected bad write)', () async {
      await File(p('note.txt')).writeAsBytes(<int>[]); // zero-length primary
      await File(p('note.txt${AtomicWrite.bakSuffix}')).writeAsString('good');
      await AtomicWrite.recoverIfNeeded(tmp.path);
      expect(await File(p('note.txt${AtomicWrite.bakSuffix}')).exists(), isTrue,
          reason: 'must not discard the only good copy');
    });

    test('deletes an orphaned namespaced staging file', () async {
      await File(p('x.bin${AtomicWrite.tmpSuffix}')).writeAsBytes([0]);
      await AtomicWrite.recoverIfNeeded(tmp.path);
      expect(await File(p('x.bin${AtomicWrite.tmpSuffix}')).exists(), isFalse);
    });

    test('does NOT delete a user file literally named report.tmp', () async {
      await File(p('report.tmp')).writeAsString('user data');
      await AtomicWrite.recoverIfNeeded(tmp.path);
      expect(await File(p('report.tmp')).exists(), isTrue);
      expect(await File(p('report.tmp')).readAsString(), 'user data');
    });

    test('does NOT touch a user file named photos.bak with no sibling', () async {
      await File(p('photos.bak')).writeAsString('user backup');
      await AtomicWrite.recoverIfNeeded(tmp.path);
      expect(await File(p('photos.bak')).exists(), isTrue);
      expect(await File(p('photos')).exists(), isFalse);
    });

    test('is a no-op on a clean directory of real files', () async {
      await File(p('a.txt')).writeAsString('a');
      await File(p('b.txt')).writeAsString('b');
      await AtomicWrite.recoverIfNeeded(tmp.path);
      expect(await File(p('a.txt')).readAsString(), 'a');
      expect(await File(p('b.txt')).readAsString(), 'b');
    });

    test('on a non-existent directory does not throw', () async {
      await AtomicWrite.recoverIfNeeded('${tmp.path}/does-not-exist');
    });

    test('restores the backup and deletes the orphan tmp after a full '
        'mid-fallback crash (both artifacts present, no primary)', () async {
      await File(p('note.txt${AtomicWrite.bakSuffix}')).writeAsString('old');
      await File(p('note.txt${AtomicWrite.tmpSuffix}')).writeAsString('new');
      await AtomicWrite.recoverIfNeeded(tmp.path);
      expect(await File(p('note.txt')).readAsString(), 'old',
          reason: 'the backup is the last known-good content');
      expect(
          await File(p('note.txt${AtomicWrite.bakSuffix}')).exists(), isFalse);
      expect(
          await File(p('note.txt${AtomicWrite.tmpSuffix}')).exists(), isFalse);
    });
  });

  group('recoverFileIfNeeded (lazy single-file repair)', () {
    test('restores a stranded backup when the primary is missing', () async {
      final path = p('lazy.txt');
      await File('$path${AtomicWrite.bakSuffix}').writeAsString('stranded');
      expect(await AtomicWrite.recoverFileIfNeeded(path), isTrue);
      expect(await File(path).readAsString(), 'stranded');
      expect(await File('$path${AtomicWrite.bakSuffix}').exists(), isFalse);
    });

    test('is a no-op when the primary exists', () async {
      final path = p('present.txt');
      await File(path).writeAsString('current');
      await File('$path${AtomicWrite.bakSuffix}').writeAsString('stale');
      expect(await AtomicWrite.recoverFileIfNeeded(path), isTrue);
      expect(await File(path).readAsString(), 'current');
      // The stale bak is left for the directory sweep to clean up.
      expect(await File('$path${AtomicWrite.bakSuffix}').exists(), isTrue);
    });

    test('returns false when neither primary nor backup exists', () async {
      expect(await AtomicWrite.recoverFileIfNeeded(p('ghost.txt')), isFalse);
    });
  });
}
