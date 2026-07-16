import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart' as pc;
import 'package:scrib_desktop/constants.dart';
import 'package:scrib_desktop/services/file_service.dart';

/// Tests the v3 self-describing KDF header and that legacy v2 files — written
/// by every prior build — still decrypt. The v2 builder below reproduces the
/// historic on-disk format independently of production code, so it is a true
/// regression guard rather than a tautology.
void main() {
  late FileService fs;
  late Directory tmp;
  const fastIters = 1000;

  setUp(() async {
    fs = FileService();
    tmp = await Directory.systemTemp.createTemp('scrib_v3_');
  });
  tearDown(() async {
    try { await tmp.delete(recursive: true); } catch (_) {}
  });

  String path(String name) => '${tmp.path}${Platform.pathSeparator}$name';

  test('new saves are written as v3 by default', () async {
    final p = path('default.scrb');
    await fs.writeScrbFile(p, 'hello', 'pw', iterations: fastIters);
    final bytes = await File(p).readAsBytes();
    expect(bytes[4], scrbVersionV3);
    expect(bytes[5], scrbKdfPbkdf2Sha256);
  });

  test('v3 stores the iteration count big-endian and round-trips a custom value', () async {
    final p = path('custom.scrb');
    await fs.writeScrbFile(p, 'tunable', 'pw', iterations: 70000);
    final bytes = await File(p).readAsBytes();
    final stored = (bytes[6] << 24) | (bytes[7] << 16) | (bytes[8] << 8) | bytes[9];
    expect(stored, 70000);
    expect(await fs.readScrbFile(p, 'pw'), 'tunable');
  });

  test('modifying the stored iteration field makes decryption fail', () async {
    final p = path('iter.scrb');
    await fs.writeScrbFile(p, 'authenticated params', 'pw', iterations: fastIters);
    final bytes = await File(p).readAsBytes();
    bytes[9] ^= 0x01; // change the low byte of the iteration count
    await File(p).writeAsBytes(bytes);
    expect(await fs.readScrbFile(p, 'pw'), isNull);
  });

  test('modifying the kdfId byte makes decryption fail', () async {
    final p = path('kdf.scrb');
    await fs.writeScrbFile(p, 'authenticated params', 'pw', iterations: fastIters);
    final bytes = await File(p).readAsBytes();
    bytes[5] = 0x09; // unknown KDF id
    await File(p).writeAsBytes(bytes);
    expect(await fs.readScrbFile(p, 'pw'), isNull);
  });

  test('v3 file truncated inside the header returns null without throwing', () async {
    final p = path('trunc.scrb');
    await fs.writeScrbFile(p, 'content', 'pw', iterations: fastIters);
    final bytes = await File(p).readAsBytes();
    await File(p).writeAsBytes(bytes.sublist(0, 8)); // magic+ver+kdfId+2 iter bytes
    expect(await fs.readScrbFile(p, 'pw'), isNull);
  });

  test('v3 default-iteration file round-trips', () async {
    final p = path('realdefault.scrb');
    await fs.writeScrbFile(p, 'real default cost', 'strong-password');
    expect(await fs.readScrbFile(p, 'strong-password'), 'real default cost');
  });

  test('a legacy v2 file still decrypts with the right password', () async {
    final p = path('legacy.scrb');
    await File(p).writeAsBytes(_buildV2('legacy note', 'old-pass'));
    expect(await fs.readScrbFile(p, 'old-pass'), 'legacy note');
  });

  test('a legacy v2 file rejects the wrong password', () async {
    final p = path('legacy2.scrb');
    await File(p).writeAsBytes(_buildV2('legacy note', 'old-pass'));
    expect(await fs.readScrbFile(p, 'wrong'), isNull);
  });

  test('a tampered legacy v2 file is rejected', () async {
    final p = path('legacy3.scrb');
    final bytes = _buildV2('legacy note', 'old-pass');
    bytes[bytes.length - 1] ^= 0xFF; // flip last ciphertext byte
    await File(p).writeAsBytes(bytes);
    expect(await fs.readScrbFile(p, 'old-pass'), isNull);
  });

  test('a crafted v3 header demanding 100,000,000 PBKDF2 iterations is '
      'rejected before any key derivation runs', () async {
    // At the measured ~0.85s per 100k iterations, deriving at 1e8 would take
    // roughly 14 minutes. The cap check must reject the header first — if it
    // ever regresses, this test times out instead of passing slowly.
    final p = path('hostile.scrb');
    await File(p).writeAsBytes(_buildV3Header(iterations: 100000000));
    final sw = Stopwatch()..start();
    expect(await fs.readScrbFile(p, 'any-password'), isNull);
    sw.stop();
    expect(sw.elapsed.inSeconds, lessThan(10),
        reason: 'rejection must happen without running the KDF');
  });

  test('an iteration count just above scrbMaxIterations is rejected', () async {
    final p = path('overcap.scrb');
    await File(p).writeAsBytes(_buildV3Header(iterations: scrbMaxIterations + 1));
    expect(await fs.readScrbFile(p, 'pw'), isNull);
  });

  test('an iteration count of zero is rejected', () async {
    final p = path('zeroiter.scrb');
    await File(p).writeAsBytes(_buildV3Header(iterations: 0));
    expect(await fs.readScrbFile(p, 'pw'), isNull);
  });

  test('the write-side default sits well inside the DoS cap', () {
    expect(scrbV3DefaultIterations, lessThanOrEqualTo(scrbMaxIterations));
    expect(scrbMaxIterations, 2000000,
        reason: 'raising the cap re-opens the decrypt-freeze DoS; see the '
            'constant doc before changing it');
  });

  test('v2 and v3 files of the same content carry different version bytes', () async {
    final v2p = path('v2.scrb');
    final v3p = path('v3.scrb');
    await File(v2p).writeAsBytes(_buildV2('same content', 'pw'));
    await fs.writeScrbFile(v3p, 'same content', 'pw', iterations: fastIters);
    final v2b = await File(v2p).readAsBytes();
    final v3b = await File(v3p).readAsBytes();
    expect(v2b[4], scrbVersionV2);
    expect(v3b[4], scrbVersionV3);
    expect(await fs.readScrbFile(v2p, 'pw'), 'same content');
    expect(await fs.readScrbFile(v3p, 'pw'), 'same content');
  });
}

/// Builds a syntactically valid v3 file whose header demands [iterations].
/// The HMAC is garbage — irrelevant, because iteration-bound rejection must
/// happen BEFORE the (KDF-dependent) HMAC check can even run.
Uint8List _buildV3Header({required int iterations}) {
  final b = BytesBuilder()
    ..add(scrbMagic)
    ..addByte(scrbVersionV3)
    ..addByte(scrbKdfPbkdf2Sha256)
    ..add([
      (iterations >> 24) & 0xFF,
      (iterations >> 16) & 0xFF,
      (iterations >> 8) & 0xFF,
      iterations & 0xFF,
    ])
    ..add(Uint8List(16)) // IV
    ..add(Uint8List(32)) // salt
    ..add(Uint8List(32)) // HMAC
    ..add(Uint8List(16)); // one block of "ciphertext"
  return b.toBytes();
}

/// Reproduces the historic v2 on-disk format:
/// [SCRB 4][ver=2 1][IV 16][salt 32][HMAC 32][ciphertext], PBKDF2-SHA256 100k.
Uint8List _buildV2(String content, String password) {
  final salt = Uint8List.fromList(List<int>.generate(32, (i) => (i * 7 + 3) & 0xFF));
  final iv = Uint8List.fromList(List<int>.generate(16, (i) => (i * 5 + 1) & 0xFF));
  final km = (pc.PBKDF2KeyDerivator(pc.HMac(pc.SHA256Digest(), 64))
        ..init(pc.Pbkdf2Parameters(salt, scrbPbkdf2Iterations, 64)))
      .process(Uint8List.fromList(utf8.encode(password)));
  final encKey = Uint8List.fromList(km.sublist(0, 32));
  final macKey = Uint8List.fromList(km.sublist(32, 64));
  final cipher = pc.PaddedBlockCipherImpl(
      pc.PKCS7Padding(), pc.CBCBlockCipher(pc.AESEngine()))
    ..init(true,
        pc.PaddedBlockCipherParameters(pc.ParametersWithIV(pc.KeyParameter(encKey), iv), null));
  final ct = cipher.process(Uint8List.fromList(utf8.encode(content)));
  final auth = (BytesBuilder()..addByte(0x02)..add(iv)..add(salt)..add(ct)).toBytes();
  final hmac = (pc.HMac(pc.SHA256Digest(), 64)..init(pc.KeyParameter(macKey))).process(auth);
  return (BytesBuilder()
        ..add(scrbMagic)
        ..addByte(0x02)
        ..add(iv)
        ..add(salt)
        ..add(hmac)
        ..add(ct))
      .toBytes();
}
