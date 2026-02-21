import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:flutter/foundation.dart' show compute;
import 'package:pointycastle/export.dart' as pc;
import '../constants.dart';

// Top-level functions run in a background isolate via compute().

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

/// Encrypt content → .scrb v2 file bytes.  Called via compute().
Uint8List _doEncrypt(Map<String, dynamic> p) {
  final content  = p['content'] as String;
  final password = p['password'] as String;
  final iv       = p['iv'] as Uint8List;
  final salt     = p['salt'] as Uint8List;

  final km     = _pbkdf2(password, salt, 100000, 64);
  final encKey = Uint8List.fromList(km.sublist(0, 32));
  final macKey = Uint8List.fromList(km.sublist(32, 64));

  final encrypter = encrypt.Encrypter(
    encrypt.AES(encrypt.Key(encKey), mode: encrypt.AESMode.cbc),
  );
  final ct = encrypter.encrypt(content, iv: encrypt.IV(iv)).bytes;

  final auth = BytesBuilder()
    ..addByte(0x02)
    ..add(iv)
    ..add(salt)
    ..add(ct);
  final hmac = _hmacSha256(macKey, auth.toBytes());

  final out = BytesBuilder()
    ..add([0x53, 0x43, 0x52, 0x42])
    ..addByte(0x02)
    ..add(iv)
    ..add(salt)
    ..add(hmac)
    ..add(ct);

  _zero(km);
  _zero(encKey);
  _zero(macKey);
  return out.toBytes();
}

/// Decrypt .scrb file bytes → plaintext (or null).  Called via compute().
String? _doDecrypt(Map<String, dynamic> p) {
  final bytes    = p['bytes'] as Uint8List;
  final password = p['password'] as String;
  final version  = bytes[4];

  if (version == 0x02) {
    if (bytes.length < 86) return null;
    final iv   = Uint8List.fromList(bytes.sublist(5, 21));
    final salt = Uint8List.fromList(bytes.sublist(21, 53));
    final mac  = Uint8List.fromList(bytes.sublist(53, 85));
    final ct   = Uint8List.fromList(bytes.sublist(85));
    if (ct.isEmpty) return null;

    final km     = _pbkdf2(password, salt, 100000, 64);
    final encKey = Uint8List.fromList(km.sublist(0, 32));
    final macKey = Uint8List.fromList(km.sublist(32, 64));
    try {
      final auth = BytesBuilder()
        ..addByte(0x02)
        ..add(iv)
        ..add(salt)
        ..add(ct);
      if (!_constantTimeEq(mac, _hmacSha256(macKey, auth.toBytes()))) {
        return null;
      }
      final d = encrypt.Encrypter(
        encrypt.AES(encrypt.Key(encKey), mode: encrypt.AESMode.cbc),
      );
      return d.decrypt(encrypt.Encrypted(ct), iv: encrypt.IV(iv));
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

/// Handles .txt, .rtf, and .scrb file I/O.
///
/// .scrb v2 format: [SCRB 4B][ver 1B][IV 16B][salt 32B][HMAC 32B][ciphertext]
/// Key derivation: PBKDF2-SHA256, 100k iterations, 64-byte output (32 enc + 32 mac).
class FileService {
  /// Read a plaintext .txt file
  Future<String> readTxtFile(String path) async =>
      File(path).readAsString(encoding: utf8);

  /// Write a plaintext .txt file (atomic: write temp, then rename)
  Future<void> writeTxtFile(String path, String content) async {
    final tmp = File('$path.tmp');
    try {
      await tmp.writeAsString(content, encoding: utf8, flush: true);
      await tmp.rename(path);
    } catch (e) {
      if (await tmp.exists()) await tmp.delete();
      rethrow;
    }
  }

  /// Read and decrypt a .scrb v2 file. Returns null on wrong password.
  Future<String?> readScrbFile(String path, String password) async {
    final bytes = await File(path).readAsBytes();
    if (bytes.length < 5) return null;
    if (bytes[0] != scrbMagic[0] || bytes[1] != scrbMagic[1] ||
        bytes[2] != scrbMagic[2] || bytes[3] != scrbMagic[3]) {
      return null;
    }
    return compute(_doDecrypt, {'bytes': bytes, 'password': password});
  }

  /// Encrypt and write a .scrb v2 file (atomic write).
  Future<void> writeScrbFile(String path, String content, String password) async {
    // AES-CBC + PKCS7 can misbehave with empty strings; use a newline as minimum.
    final safe = content.isEmpty ? '\n' : content;

    final rng  = Random.secure();
    final iv   = Uint8List(16);
    final salt = Uint8List(32);
    for (int i = 0; i < 16; i++) {
      iv[i] = rng.nextInt(256);
    }
    for (int i = 0; i < 32; i++) {
      salt[i] = rng.nextInt(256);
    }

    final fileBytes = await compute(_doEncrypt, {
      'content': safe,
      'password': password,
      'iv': iv,
      'salt': salt,
    });

    final tmp = File('$path.tmp');
    try {
      await tmp.writeAsBytes(fileBytes, flush: true);
      await tmp.rename(path);
    } catch (e) {
      if (await tmp.exists()) await tmp.delete();
      rethrow;
    }
  }

  /// Read a .rtf file. Tries UTF-8; falls back to Latin-1 for Word-style files.
  Future<String> readRtfFile(String path) async {
    final bytes = await File(path).readAsBytes();
    try {
      return utf8.decode(bytes);
    } catch (_) {
      return latin1.decode(bytes);
    }
  }

  /// Write a .rtf file (atomic: write temp, then rename)
  Future<void> writeRtfFile(String path, String content) async {
    final tmp = File('$path.tmp');
    try {
      await tmp.writeAsString(content, encoding: utf8, flush: true);
      await tmp.rename(path);
    } catch (e) {
      if (await tmp.exists()) await tmp.delete();
      rethrow;
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
