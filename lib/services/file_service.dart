import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show compute;
import 'package:pointycastle/export.dart' as pc;
import '../constants.dart';
import 'atomic_write.dart';

// ── Isolate helpers ─────────────────────────────────────────────────────────

Uint8List _pbkdf2(String password, Uint8List salt, int iterations, int keyLen) {
  final pbkdf2 = pc.PBKDF2KeyDerivator(pc.HMac(pc.SHA256Digest(), 64));
  pbkdf2.init(pc.Pbkdf2Parameters(salt, iterations, keyLen));
  return pbkdf2.process(Uint8List.fromList(utf8.encode(password)));
}

Uint8List _hmacSha256(Uint8List key, Uint8List data) {
  final hmac = pc.HMac(pc.SHA256Digest(), 64);
  hmac.init(pc.KeyParameter(key));
  return hmac.process(data);
}

bool _constantTimeEq(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  int r = 0;
  for (int i = 0; i < a.length; i++) {
    r |= a[i] ^ b[i];
  }
  return r == 0;
}

void _zero(Uint8List b) {
  for (int i = 0; i < b.length; i++) {
    b[i] = 0;
  }
}

Uint8List _aesCbcEncrypt(Uint8List key, Uint8List iv, Uint8List plaintext) {
  final cipher = pc.PaddedBlockCipherImpl(
    pc.PKCS7Padding(),
    pc.CBCBlockCipher(pc.AESEngine()),
  );
  final params = pc.PaddedBlockCipherParameters<pc.CipherParameters, pc.CipherParameters>(
    pc.ParametersWithIV<pc.KeyParameter>(pc.KeyParameter(key), iv),
    null,
  );
  cipher.init(true, params);
  return cipher.process(plaintext);
}

Uint8List _aesCbcDecrypt(Uint8List key, Uint8List iv, Uint8List ciphertext) {
  final cipher = pc.PaddedBlockCipherImpl(
    pc.PKCS7Padding(),
    pc.CBCBlockCipher(pc.AESEngine()),
  );
  final params = pc.PaddedBlockCipherParameters<pc.CipherParameters, pc.CipherParameters>(
    pc.ParametersWithIV<pc.KeyParameter>(pc.KeyParameter(key), iv),
    null,
  );
  cipher.init(false, params);
  return cipher.process(ciphertext);
}

/// Encrypt content → .scrb v2 file bytes.  Called via compute().
/// Byte layout is unchanged from v1.1.x — existing files remain readable.
Uint8List _doEncrypt(Map<String, dynamic> p) {
  final content  = p['content'] as String;
  final password = p['password'] as String;
  final iv       = p['iv'] as Uint8List;
  final salt     = p['salt'] as Uint8List;

  final km     = _pbkdf2(password, salt, scrbPbkdf2Iterations, scrbKeyMaterialLength);
  final encKey = Uint8List.fromList(km.sublist(0, 32));
  final macKey = Uint8List.fromList(km.sublist(32, 64));

  final ct = _aesCbcEncrypt(encKey, iv, Uint8List.fromList(utf8.encode(content)));

  final auth = BytesBuilder()
    ..addByte(scrbVersionV2)
    ..add(iv)
    ..add(salt)
    ..add(ct);
  final hmac = _hmacSha256(macKey, auth.toBytes());

  final out = BytesBuilder()
    ..add(scrbMagic)
    ..addByte(scrbVersionV2)
    ..add(iv)
    ..add(salt)
    ..add(hmac)
    ..add(ct);

  _zero(km);
  _zero(encKey);
  _zero(macKey);
  return out.toBytes();
}

/// Decrypt .scrb file bytes → plaintext (or null on wrong password / tamper).
/// Called via compute().
String? _doDecrypt(Map<String, dynamic> p) {
  final bytes    = p['bytes'] as Uint8List;
  final password = p['password'] as String;
  if (bytes.length < 5) return null;
  final version  = bytes[4];

  if (version == scrbVersionV2) {
    // Header: [magic 4][ver 1][iv 16][salt 32][hmac 32] = 85 bytes.
    // Ciphertext must be at least one AES block (16 bytes) after padding.
    if (bytes.length < 85 + 16) return null;
    final iv   = Uint8List.fromList(bytes.sublist(5, 21));
    final salt = Uint8List.fromList(bytes.sublist(21, 53));
    final mac  = Uint8List.fromList(bytes.sublist(53, 85));
    final ct   = Uint8List.fromList(bytes.sublist(85));
    if (ct.isEmpty) return null;

    final km     = _pbkdf2(password, salt, scrbPbkdf2Iterations, scrbKeyMaterialLength);
    final encKey = Uint8List.fromList(km.sublist(0, 32));
    final macKey = Uint8List.fromList(km.sublist(32, 64));
    try {
      final auth = BytesBuilder()
        ..addByte(version)
        ..add(iv)
        ..add(salt)
        ..add(ct);
      if (!_constantTimeEq(mac, _hmacSha256(macKey, auth.toBytes()))) {
        return null;
      }
      final plaintext = _aesCbcDecrypt(encKey, iv, ct);
      return utf8.decode(plaintext);
    } catch (_) {
      return null;
    } finally {
      _zero(km);
      _zero(encKey);
      _zero(macKey);
    }
  }
  return null;
}

// ── Exceptions ──────────────────────────────────────────────────────────────

/// Thrown when the file can't be read from disk (I/O error).
class ScribFileReadException implements Exception {
  final String path;
  ScribFileReadException(this.path);
  @override
  String toString() => 'Could not read file';
}

/// Thrown when the file can't be written to disk (disk full, permissions).
class ScribFileWriteException implements Exception {
  final String path;
  ScribFileWriteException(this.path);
  @override
  String toString() => 'Could not save file';
}

// ── Service ─────────────────────────────────────────────────────────────────

/// Handles .txt, .rtf, and .scrb file I/O.
///
/// .scrb v2 format: [SCRB 4B][ver 1B][IV 16B][salt 32B][HMAC 32B][ciphertext]
/// Key derivation: PBKDF2-SHA256, 100k iterations, 64-byte output (32 enc + 32 mac).
///
/// All writes are atomic on Windows via MoveFileExW — see atomic_write.dart.
class FileService {
  /// Read a plaintext .txt file
  Future<String> readTxtFile(String path) async {
    try {
      return await File(path).readAsString(encoding: utf8);
    } catch (_) {
      throw ScribFileReadException(path);
    }
  }

  /// Write a plaintext .txt file atomically.
  Future<void> writeTxtFile(String path, String content) async {
    try {
      await AtomicWrite.writeString(path, content);
    } catch (_) {
      throw ScribFileWriteException(path);
    }
  }

  /// Read and decrypt a .scrb v2 file. Returns null on wrong password or tamper.
  Future<String?> readScrbFile(String path, String password) async {
    final Uint8List bytes;
    try {
      bytes = await File(path).readAsBytes();
    } catch (_) {
      throw ScribFileReadException(path);
    }
    if (bytes.length < 5) return null;
    if (bytes[0] != scrbMagic[0] || bytes[1] != scrbMagic[1] ||
        bytes[2] != scrbMagic[2] || bytes[3] != scrbMagic[3]) {
      return null;
    }
    return compute(_doDecrypt, {'bytes': bytes, 'password': password});
  }

  /// Encrypt and write a .scrb v2 file atomically.
  Future<void> writeScrbFile(String path, String content, String password) async {
    // AES-CBC + PKCS7 can misbehave with empty strings; use a newline as minimum.
    // Backward-compatible with v1.1.x: existing empty encrypted files remain readable.
    final safe = content.isEmpty ? '\n' : content;

    final rng  = Random.secure();
    final iv   = Uint8List(scrbIvLength);
    final salt = Uint8List(scrbSaltLength);
    for (int i = 0; i < scrbIvLength; i++) {
      iv[i] = rng.nextInt(256);
    }
    for (int i = 0; i < scrbSaltLength; i++) {
      salt[i] = rng.nextInt(256);
    }

    final fileBytes = await compute(_doEncrypt, {
      'content': safe,
      'password': password,
      'iv': iv,
      'salt': salt,
    });

    try {
      await AtomicWrite.writeBytes(path, fileBytes);
    } catch (_) {
      throw ScribFileWriteException(path);
    }
  }

  /// Read a .rtf file. Tries UTF-8; falls back to Latin-1 for Word-style files.
  Future<String> readRtfFile(String path) async {
    final Uint8List bytes;
    try {
      bytes = await File(path).readAsBytes();
    } catch (_) {
      throw ScribFileReadException(path);
    }
    try {
      return utf8.decode(bytes);
    } catch (_) {
      return latin1.decode(bytes);
    }
  }

  /// Write a .rtf file atomically.
  Future<void> writeRtfFile(String path, String content) async {
    try {
      await AtomicWrite.writeString(path, content);
    } catch (_) {
      throw ScribFileWriteException(path);
    }
  }

  /// Check if a file is a .scrb encrypted file by reading magic bytes
  Future<bool> isScrbFile(String path) async {
    final file = File(path);
    if (!await file.exists()) return false;
    final bytes = await file.openRead(0, 4).fold<List<int>>(
      [],
      (prev, chunk) => prev..addAll(chunk),
    );
    if (bytes.length < 4) return false;
    return bytes[0] == scrbMagic[0] && bytes[1] == scrbMagic[1] &&
           bytes[2] == scrbMagic[2] && bytes[3] == scrbMagic[3];
  }

  /// Get file extension
  String getExtension(String path) {
    final dot = path.lastIndexOf('.');
    if (dot == -1) return '';
    return path.substring(dot).toLowerCase();
  }

  /// Get filename from path
  String getFileName(String path) {
    return path.split(Platform.pathSeparator).last;
  }
}
