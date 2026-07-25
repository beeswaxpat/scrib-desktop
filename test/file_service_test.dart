import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrib_desktop/constants.dart';
import 'package:scrib_desktop/services/atomic_write.dart';
import 'package:scrib_desktop/services/file_service.dart';

/// Tests for the .scrb v2 file format and plaintext .txt I/O.
///
/// These tests protect the most important promise we make to users: an
/// encrypted file written by any 1.x build must decrypt to the same
/// plaintext in any subsequent 1.x build, using the same password.
void main() {
  late FileService fs;
  late Directory tmp;

  setUp(() async {
    fs = FileService();
    tmp = await Directory.systemTemp.createTemp('scrib_test_');
  });

  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  String path(String name) => '${tmp.path}${Platform.pathSeparator}$name';

  group('.scrb encryption round-trip', () {
    test('basic encrypt → decrypt returns original plaintext', () async {
      const content = 'Hello, Scrib!';
      const password = 'correct horse battery staple';
      final p = path('basic.scrb');

      await fs.writeScrbFile(p, content, password);
      final decrypted = await fs.readScrbFile(p, password);
      expect(decrypted, content);
    });

    test('wrong password returns null (not a crash)', () async {
      const content = 'secret';
      final p = path('wrong.scrb');

      await fs.writeScrbFile(p, content, 'real-password-123');
      expect(await fs.readScrbFile(p, 'wrong-password'), isNull);
    });

    test('tampered ciphertext returns null (HMAC rejects)', () async {
      const content = 'integrity matters';
      const password = 'tamper-test-password';
      final p = path('tamper.scrb');

      await fs.writeScrbFile(p, content, password);
      final bytes = await File(p).readAsBytes();
      // Flip a single bit in the ciphertext body (after the 85-byte header).
      final tampered = Uint8List.fromList(bytes);
      tampered[100] ^= 0x01;
      await File(p).writeAsBytes(tampered);

      expect(await fs.readScrbFile(p, password), isNull);
    });

    test('tampered IV returns null (HMAC covers IV)', () async {
      const content = 'iv protection';
      const password = 'hmac-covers-iv-test';
      final p = path('iv_tamper.scrb');

      await fs.writeScrbFile(p, content, password);
      final bytes = await File(p).readAsBytes();
      final tampered = Uint8List.fromList(bytes);
      // Flip the first byte of the IV (offset 5).
      tampered[5] ^= 0xFF;
      await File(p).writeAsBytes(tampered);

      expect(await fs.readScrbFile(p, password), isNull);
    });

    test('tampered salt returns null (HMAC covers salt)', () async {
      const content = 'salt protection';
      const password = 'hmac-covers-salt-test';
      final p = path('salt_tamper.scrb');

      await fs.writeScrbFile(p, content, password);
      final bytes = await File(p).readAsBytes();
      final tampered = Uint8List.fromList(bytes);
      tampered[21] ^= 0xFF; // first byte of salt
      await File(p).writeAsBytes(tampered);

      expect(await fs.readScrbFile(p, password), isNull);
    });

    test('magic bytes mismatch returns null (not a .scrb file)', () async {
      final p = path('fake.scrb');
      await File(p).writeAsBytes([0, 0, 0, 0, 2, 0, 0, 0, 0]);
      expect(await fs.readScrbFile(p, 'any-password'), isNull);
    });

    test('file shorter than header returns null', () async {
      final p = path('short.scrb');
      await File(p).writeAsBytes([0x53, 0x43, 0x52, 0x42]); // magic only
      expect(await fs.readScrbFile(p, 'anything'), isNull);
    });

    test('empty content round-trips (writes a newline internally)', () async {
      const password = 'empty-content-ok';
      final p = path('empty.scrb');

      await fs.writeScrbFile(p, '', password);
      // v1.1.x used a '\n' workaround for empty content; preserved for
      // backward compatibility with already-saved user files.
      expect(await fs.readScrbFile(p, password), '\n');
    });

    test('large content (1MB+) round-trips', () async {
      final content = 'x' * (1024 * 1024 + 7); // 1MB + 7 bytes
      const password = 'big-file-password';
      final p = path('large.scrb');

      await fs.writeScrbFile(p, content, password);
      expect(await fs.readScrbFile(p, password), content);
    });

    test('unicode content round-trips', () async {
      const content = 'Hello 世界 🔒 Здравствуй мир';
      const password = 'unicode-password-öñ';
      final p = path('unicode.scrb');

      await fs.writeScrbFile(p, content, password);
      expect(await fs.readScrbFile(p, password), content);
    });

    test('each save uses fresh IV and salt (no deterministic ciphertext)', () async {
      const content = 'same plaintext';
      const password = 'same-password';
      final p1 = path('rand1.scrb');
      final p2 = path('rand2.scrb');

      await fs.writeScrbFile(p1, content, password);
      await fs.writeScrbFile(p2, content, password);

      final b1 = await File(p1).readAsBytes();
      final b2 = await File(p2).readAsBytes();

      // Magic + version should be identical; everything else must differ.
      expect(b1.sublist(0, 5), b2.sublist(0, 5)); // magic + version
      expect(b1.sublist(5, 21), isNot(equals(b2.sublist(5, 21)))); // IV
      expect(b1.sublist(21, 53), isNot(equals(b2.sublist(21, 53)))); // salt
      expect(b1.sublist(53, 85), isNot(equals(b2.sublist(53, 85)))); // HMAC
    });

    test('.scrb byte layout matches documented v3 format', () async {
      const content = 'format check';
      const password = 'format-check-password';
      final p = path('layout.scrb');

      // New saves are v3: [magic 4][ver 1][kdfId 1][iters 4][IV 16][salt 32][HMAC 32][ct].
      await fs.writeScrbFile(p, content, password, iterations: 1000);
      final bytes = await File(p).readAsBytes();

      expect(bytes.sublist(0, 4), scrbMagic); // SCRB
      expect(bytes[4], scrbVersionV3);
      expect(bytes[5], scrbKdfPbkdf2Sha256);
      // iterations stored big-endian uint32 at offset 6
      final iters = (bytes[6] << 24) | (bytes[7] << 16) | (bytes[8] << 8) | bytes[9];
      expect(iters, 1000);
      expect(bytes.length, greaterThanOrEqualTo(90 + 16));
    });

    test('isScrbFile detects magic bytes', () async {
      final scrbPath = path('real.scrb');
      final txtPath = path('plain.txt');

      await fs.writeScrbFile(scrbPath, 'hello', 'password-here');
      await fs.writeTxtFile(txtPath, 'hello');

      expect(await fs.isScrbFile(scrbPath), isTrue);
      expect(await fs.isScrbFile(txtPath), isFalse);
    });
  });

  group('plaintext .txt round-trip', () {
    test('write then read returns same content', () async {
      const content = 'plain text note\nwith multiple\nlines';
      final p = path('note.txt');

      await fs.writeTxtFile(p, content);
      expect(await fs.readTxtFile(p), content);
    });

    test('atomic write over existing file succeeds', () async {
      final p = path('existing.txt');

      await fs.writeTxtFile(p, 'version 1');
      await fs.writeTxtFile(p, 'version 2');

      expect(await fs.readTxtFile(p), 'version 2');
    });

    test('utf-8 content round-trips', () async {
      const content = 'Zażółć gęślą jaźń — 中文 — ñ ö ü';
      final p = path('unicode.txt');

      await fs.writeTxtFile(p, content);
      expect(await fs.readTxtFile(p), content);
    });

    test('read of non-existent file throws ScribFileReadException', () async {
      expect(
        () => fs.readTxtFile(path('does-not-exist.txt')),
        throwsA(isA<ScribFileReadException>()),
      );
    });
  });

  group('lazy crash repair on read', () {
    test('readTxtFile restores a stranded .scrib-bak before reading', () async {
      final p = path('stranded.txt');
      await File('$p${AtomicWrite.bakSuffix}').writeAsString('recovered body');
      expect(await fs.readTxtFile(p), 'recovered body');
      expect(await File(p).exists(), isTrue);
      expect(await File('$p${AtomicWrite.bakSuffix}').exists(), isFalse);
    });

    test('readScrbFile restores a stranded encrypted .scrib-bak and decrypts it', () async {
      final p = path('stranded.scrb');
      await fs.writeScrbFile(p, 'survived the crash', 'pw', iterations: 1000);
      // Simulate a crash mid-fallback-rename: content sits at the backup path,
      // primary is gone.
      await File(p).rename('$p${AtomicWrite.bakSuffix}');
      expect(await fs.readScrbFile(p, 'pw'), 'survived the crash');
    });

    test('readRtfFile restores a stranded .scrib-bak before reading', () async {
      final p = path('stranded.rtf');
      await File('$p${AtomicWrite.bakSuffix}')
          .writeAsString(r'{\rtf1\ansi\deff0 rescued\par}');
      expect(await fs.readRtfFile(p), contains('rescued'));
    });
  });

  group('path helpers', () {
    test('getExtension returns lowercase extension with dot', () {
      expect(fs.getExtension('note.TXT'), '.txt');
      expect(fs.getExtension('archive.tar.gz'), '.gz');
      expect(fs.getExtension('no-extension'), '');
    });

    test('getFileName strips directory prefix', () {
      final pSep = Platform.pathSeparator;
      expect(fs.getFileName('C:${pSep}Users${pSep}test${pSep}file.txt'), 'file.txt');
      expect(fs.getFileName('file.txt'), 'file.txt');
    });
  });

  group('read-path robustness', () {
    test('a non-UTF-8 text file opens via the Latin-1 fallback', () async {
      final p = '${tmp.path}${Platform.pathSeparator}legacy.log';
      // 0xE9 is 'e-acute' in cp1252/Latin-1 and invalid on its own in UTF-8.
      // Windows tools write files like this constantly; refusing them made
      // ordinary .log / .csv / .ini files unopenable.
      await File(p).writeAsBytes([0x63, 0x61, 0x66, 0xE9]);
      expect(await fs.readTxtFile(p), 'café');
    });

    test('a file larger than the read cap is refused, not loaded', () async {
      final p = '${tmp.path}${Platform.pathSeparator}huge.txt';
      final f = File(p);
      final sink = f.openWrite();
      final chunk = List<int>.filled(1024 * 1024, 0x41);
      for (var i = 0; i < FileService.maxReadBytes ~/ chunk.length + 1; i++) {
        sink.add(chunk);
      }
      await sink.close();
      await expectLater(fs.readTxtFile(p),
          throwsA(isA<ScribFileTooLargeException>()));
    });
  });
}
