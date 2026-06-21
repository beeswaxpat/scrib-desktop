import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:ffi/ffi.dart';

/// Windows-safe atomic file writes.
///
/// Dart's `File.rename()` delegates to `MoveFileW` on Windows, which refuses
/// to overwrite an existing destination. For an encrypted editor that's a
/// hard correctness bug: saves would fail silently on any file that already
/// exists.
///
/// This helper uses `MoveFileExW` with `MOVEFILE_REPLACE_EXISTING |
/// MOVEFILE_WRITE_THROUGH`, which is documented as atomic on NTFS and
/// flushes the file system cache before returning. If ffi fails for any
/// reason (non-Windows, loader issues, ReFS, mapped drives), we fall back
/// to a crash-safe two-step rename: the existing file is moved aside to a
/// Scrib-namespaced backup before the new content is renamed into place, and
/// restored if the rename fails. Worst case, a crash between the two renames
/// leaves the user's previous content at `<path>.scrib-bak` — recoverable,
/// never lost.
///
/// Temp and backup files use Scrib-specific suffixes (not the generic `.tmp` /
/// `.bak`) so crash recovery can never delete or relocate an unrelated user
/// file that merely happens to end in `.tmp` or `.bak`.
class AtomicWrite {
  /// Suffix for the staging file written before the atomic rename.
  static const String tmpSuffix = '.scrib-tmp';

  /// Suffix for the previous-content backup made during the fallback rename.
  static const String bakSuffix = '.scrib-bak';

  /// Test seam: when true, [_renameReplacing] skips the Windows ffi path and
  /// always uses the pure-Dart [_crashSafeRename] fallback, so the fallback and
  /// its `.scrib-bak` behavior can be exercised on Windows. Production code
  /// never sets this.
  @visibleForTesting
  static bool debugForceFallback = false;

  /// Serializes writes per destination path so two overlapping saves (rapid
  /// Ctrl+S, auto-save racing a manual save, two tabs on the same file) can
  /// never interleave into the shared staging/backup files.
  static final Map<String, Future<void>> _writeLocks = {};

  static Future<void> _withPathLock(String path, Future<void> Function() action) async {
    final prev = _writeLocks[path] ?? Future<void>.value();
    final completer = Completer<void>();
    _writeLocks[path] = completer.future;
    try {
      await prev; // never completes with an error — see finally below
      await action();
    } finally {
      completer.complete();
      if (identical(_writeLocks[path], completer.future)) {
        _writeLocks.remove(path);
      }
    }
  }

  /// Write [bytes] to [path] atomically. On Windows, uses MoveFileExW.
  /// Falls back to a crash-safe two-step rename on other platforms or if
  /// the ffi call fails.
  static Future<void> writeBytes(String path, Uint8List bytes) {
    return _withPathLock(path, () async {
      final tmpPath = '$path$tmpSuffix';
      final tmp = File(tmpPath);
      await tmp.writeAsBytes(bytes, flush: true);
      try {
        await _renameReplacing(tmpPath, path);
      } catch (e) {
        if (await tmp.exists()) {
          try { await tmp.delete(); } catch (_) {}
        }
        rethrow;
      }
    });
  }

  /// Write [content] to [path] atomically as UTF-8.
  static Future<void> writeString(String path, String content) {
    return _withPathLock(path, () async {
      final tmpPath = '$path$tmpSuffix';
      final tmp = File(tmpPath);
      await tmp.writeAsString(content, flush: true);
      try {
        await _renameReplacing(tmpPath, path);
      } catch (e) {
        if (await tmp.exists()) {
          try { await tmp.delete(); } catch (_) {}
        }
        rethrow;
      }
    });
  }

  /// Rename [src] to [dst], replacing [dst] if it exists.
  static Future<void> _renameReplacing(String src, String dst) async {
    if (Platform.isWindows && !debugForceFallback) {
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

      // toNativeUtf16 allocates via `malloc`, so free via `malloc` to keep the
      // allocator symmetric.
      final srcPtr = src.toNativeUtf16();
      final dstPtr = dst.toNativeUtf16();
      try {
        // 0x01 = MOVEFILE_REPLACE_EXISTING, 0x08 = MOVEFILE_WRITE_THROUGH
        final result = moveFileExW(srcPtr, dstPtr, 0x01 | 0x08);
        return result != 0;
      } finally {
        malloc.free(srcPtr);
        malloc.free(dstPtr);
      }
    } catch (_) {
      return false;
    }
  }

  /// Pure-Dart fallback. On a crash between the two renames, the user's
  /// previous content survives at `$dst$bakSuffix` and the new content at
  /// `$src`. A follow-up call to [recoverIfNeeded] on app start restores it.
  static Future<void> _crashSafeRename(String src, String dst) async {
    final target = File(dst);
    if (!await target.exists()) {
      await File(src).rename(dst);
      return;
    }
    final bak = File('$dst$bakSuffix');
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

  /// Best-effort recovery of any stranded staging / backup files from a prior
  /// crash. Only files with Scrib's own [tmpSuffix] / [bakSuffix] are touched,
  /// so unrelated user files ending in `.tmp` or `.bak` are never affected.
  /// Called on app start for the default save directory.
  static Future<void> recoverIfNeeded(String directory) async {
    final dir = Directory(directory);
    if (!await dir.exists()) return;
    await for (final entry in dir.list(followLinks: false)) {
      if (entry is! File) continue;
      final name = entry.path;
      if (name.endsWith(bakSuffix)) {
        // A backup without a matching primary means the rename was interrupted
        // before the new file landed — restore the backup.
        final primary = name.substring(0, name.length - bakSuffix.length);
        final primaryFile = File(primary);
        if (!await primaryFile.exists()) {
          try { await entry.rename(primary); } catch (_) {}
        } else {
          // Both exist. Normally the primary is the newer successful rename and
          // the backup is stale — but only discard the backup if the primary
          // looks intact (non-empty). A zero-length primary suggests an
          // interrupted write, so keep the backup for manual recovery.
          bool primaryOk;
          try {
            primaryOk = (await primaryFile.length()) > 0;
          } catch (_) {
            primaryOk = false;
          }
          if (primaryOk) {
            try { await entry.delete(); } catch (_) {}
          }
        }
      } else if (name.endsWith(tmpSuffix)) {
        // Orphaned staging file from a crash before the rename — safe to remove.
        try { await entry.delete(); } catch (_) {}
      }
    }
  }
}
