import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';

/// Windows-safe atomic file writes.
///
/// Dart's `File.rename()` delegates to `MoveFileW` on Windows, which refuses
/// to overwrite an existing destination. For an encrypted editor that's a
/// hard correctness bug: users would see `.tmp` files litter their disk and
/// saves would fail silently on any file that already exists.
///
/// This helper uses `MoveFileExW` with `MOVEFILE_REPLACE_EXISTING |
/// MOVEFILE_WRITE_THROUGH`, which is documented as atomic on NTFS and
/// flushes the file system cache before returning. If ffi fails for any
/// reason (non-Windows, loader issues, ReFS, mapped drives), we fall back
/// to a crash-safe two-step rename: the existing file is moved aside to
/// `.bak` before the new content is renamed into place, and restored if
/// the rename fails. Worst case, a crash between the two renames leaves
/// the user's previous content at `<path>.bak` — recoverable, never lost.
class AtomicWrite {
  /// Write [bytes] to [path] atomically. On Windows, uses MoveFileExW.
  /// Falls back to a crash-safe two-step rename on other platforms or if
  /// the ffi call fails.
  static Future<void> writeBytes(String path, Uint8List bytes) async {
    final tmp = File('$path.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    try {
      await _renameReplacing(tmp.path, path);
    } catch (e) {
      if (await tmp.exists()) {
        try { await tmp.delete(); } catch (_) {}
      }
      rethrow;
    }
  }

  /// Write [content] to [path] atomically as UTF-8.
  static Future<void> writeString(String path, String content) async {
    final tmp = File('$path.tmp');
    await tmp.writeAsString(content, flush: true);
    try {
      await _renameReplacing(tmp.path, path);
    } catch (e) {
      if (await tmp.exists()) {
        try { await tmp.delete(); } catch (_) {}
      }
      rethrow;
    }
  }

  /// Rename [src] to [dst], replacing [dst] if it exists.
  static Future<void> _renameReplacing(String src, String dst) async {
    if (Platform.isWindows) {
      if (_moveFileExReplace(src, dst)) return;
      // Fall through to the pure-Dart fallback if ffi fails.
    }
    await _crashSafeRename(src, dst);
  }

  /// MoveFileExW with MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH.
  /// Returns true on success, false on any failure.
  static bool _moveFileExReplace(String src, String dst) {
    try {
      final kernel32 = DynamicLibrary.open('kernel32.dll');
      final moveFileExW = kernel32.lookupFunction<
          Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Uint32),
          int Function(Pointer<Utf16>, Pointer<Utf16>, int)>('MoveFileExW');

      final srcPtr = src.toNativeUtf16();
      final dstPtr = dst.toNativeUtf16();
      try {
        // 0x01 = MOVEFILE_REPLACE_EXISTING, 0x08 = MOVEFILE_WRITE_THROUGH
        final result = moveFileExW(srcPtr, dstPtr, 0x01 | 0x08);
        return result != 0;
      } finally {
        calloc.free(srcPtr);
        calloc.free(dstPtr);
      }
    } catch (_) {
      return false;
    }
  }

  /// Pure-Dart fallback. On a crash between the two renames, the user's
  /// previous content survives at `$dst.bak` and the new content at `$src`.
  /// A follow-up call to [recoverIfNeeded] on app start restores either one.
  static Future<void> _crashSafeRename(String src, String dst) async {
    final target = File(dst);
    if (!await target.exists()) {
      await File(src).rename(dst);
      return;
    }
    final bak = File('$dst.bak');
    if (await bak.exists()) {
      try { await bak.delete(); } catch (_) {}
    }
    await target.rename(bak.path);
    try {
      await File(src).rename(dst);
      try { await bak.delete(); } catch (_) {}
    } catch (e) {
      // Restore previous content.
      try { await bak.rename(dst); } catch (_) {}
      rethrow;
    }
  }

  /// Best-effort recovery of any stranded `.tmp` / `.bak` files from a prior
  /// crash. Called on app start for the default save directory.
  static Future<void> recoverIfNeeded(String directory) async {
    final dir = Directory(directory);
    if (!await dir.exists()) return;
    await for (final entry in dir.list(followLinks: false)) {
      if (entry is! File) continue;
      final name = entry.path;
      if (name.endsWith('.bak')) {
        // A .bak without a matching primary means the rename was interrupted
        // before the new file landed — restore the backup.
        final primary = name.substring(0, name.length - 4);
        if (!await File(primary).exists()) {
          try { await entry.rename(primary); } catch (_) {}
        } else {
          // Both exist — primary is newer (successful rename), .bak is stale.
          try { await entry.delete(); } catch (_) {}
        }
      } else if (name.endsWith('.tmp')) {
        // Orphaned temp from a crash before the rename — safe to remove.
        try { await entry.delete(); } catch (_) {}
      }
    }
  }
}
