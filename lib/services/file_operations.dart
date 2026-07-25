import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import '../providers/editor_provider.dart';
import 'atomic_write.dart' show canonicalPath;
import 'file_service.dart';
import 'rtf_service.dart';
import 'settings_service.dart';

/// Error string returned when the user declined to replace an existing file at
/// an extension-swap destination. Distinct from a plain 'Cancelled' so the UI
/// can tell the user nothing was saved: they pressed Ctrl+S and the tab is
/// still dirty (and, after Ctrl+E, still flagged encrypted over a plaintext
/// path), which is not obvious from the dialog alone.
const String saveOverwriteDeclined = 'Overwrite declined';

/// Outcome of a save / save-as operation. The `extensionChanged` flag tells
/// the caller whether the on-disk file was renamed to a different extension
/// (e.g. .scrb → .txt when decrypting) so it can surface a SnackBar to the
/// user instead of silently moving files around.
class SaveResult {
  final bool ok;
  final String? newPath;
  final bool extensionChanged;
  final String? error;

  /// Non-fatal advisory surfaced to the user (e.g. the original plaintext file
  /// could not be removed after encrypting). The save itself still succeeded.
  final String? warning;

  const SaveResult({
    required this.ok,
    this.newPath,
    this.extensionChanged = false,
    this.error,
    this.warning,
  });

  factory SaveResult.success(
          {String? newPath, bool extensionChanged = false, String? warning}) =>
      SaveResult(
          ok: true,
          newPath: newPath,
          extensionChanged: extensionChanged,
          warning: warning);
  factory SaveResult.failure(String error) =>
      SaveResult(ok: false, error: error);
}

/// Coordinates open/save/save-as across plain text, rich text (RTF), and
/// encrypted (.scrb) formats. Stateless — all state lives on the tab.
class FileOperations {
  final FileService _fileService;
  final SettingsService _settings;

  FileOperations(this._fileService, this._settings);

  /// Save the active tab to its existing path. The caller is responsible for
  /// routing "needs a password" and "needs save-as" cases via [needsPassword]
  /// and [needsSaveAs] on the result.
  ///
  /// Handles the encryption-toggle extension swap (.scrb ↔ .txt/.rtf) and the
  /// mode-toggle format swap (.txt ↔ .rtf), returning `extensionChanged: true`
  /// so the UI can notify the user.
  ///
  /// [confirmLossyRtf] is asked before any Delta→RTF write whose Delta carries
  /// image/table embeds, because RTF conversion drops them. Return false (or
  /// pass null) to cancel that write; the tab then stays dirty.
  ///
  /// [confirmOverwrite] is asked before any extension swap whose destination
  /// already holds a DIFFERENT file. Return false (or pass null) to cancel;
  /// the original is then left untouched on disk.
  Future<SaveResult> saveActive(
    EditorProvider editor, {
    required String? passwordForNewEncryption,
    Future<bool> Function()? confirmLossyRtf,
    Future<bool> Function(String path)? confirmOverwrite,
  }) async {
    final tab = editor.activeTab;
    if (tab == null) return SaveResult.failure('No active tab');
    // A locked tab holds no decrypted content — any write path from here
    // would clobber the encrypted file with an empty document.
    if (tab.isLocked) return SaveResult.failure('Tab is locked');
    if (tab.filePath == null) return SaveResult.failure('Needs save-as');

    final currentPath = tab.filePath!;
    final isRtfOnDisk = currentPath.toLowerCase().endsWith('.rtf');
    final isScrbOnDisk = currentPath.toLowerCase().endsWith('.scrb');
    final isRichWithDelta =
        tab.mode == EditorMode.richText && tab.deltaJson.isNotEmpty;

    // Any Delta→RTF conversion silently drops image/table embeds, whose bytes
    // live only inside the Delta. Never do that without the user's say-so.
    Future<bool> rtfWriteAllowed() async {
      if (!deltaHasEmbeds(tab.deltaJson)) return true;
      return confirmLossyRtf != null && await confirmLossyRtf();
    }

    // An extension swap writes a path the user never picked, and AtomicWrite
    // replaces the destination outright (MOVEFILE_REPLACE_EXISTING leaves no
    // .scrib-bak). Each swap branch also deletes the source afterwards, so an
    // unguarded swap destroys TWO files. Never replace a different file
    // without asking; with no callback wired, refuse rather than clobber.
    Future<bool> overwriteAllowed(String newPath) async {
      if (canonicalPath(newPath) == canonicalPath(currentPath)) return true;
      if (!await File(newPath).exists()) return true;
      if (confirmOverwrite == null) return false;
      return confirmOverwrite(newPath);
    }

    try {
      // Case A: tab switched to encrypted, but file on disk is .txt/.rtf
      // → rename to .scrb and encrypt.
      if (tab.isEncrypted && !isScrbOnDisk) {
        final newPath = _swapExtension(currentPath, '.scrb');
        if (tab.password == null && passwordForNewEncryption == null) {
          return SaveResult.failure('Password required');
        }
        if (!await overwriteAllowed(newPath)) {
          return SaveResult.failure(saveOverwriteDeclined);
        }
        tab.password ??= passwordForNewEncryption;
        final wrote = await editor.saveActiveTabAs(newPath,
            encrypted: true, password: tab.password);
        // The refusal (locked mid-flow) must not fall through to deleting the
        // plaintext original of a file that was never encrypted.
        if (!wrote) return SaveResult.failure('Tab is locked');
        // Remove the now-orphaned plaintext original — leaving it on disk would
        // defeat the point of encrypting.
        final removed = await _deleteOldFile(currentPath, newPath);
        return SaveResult.success(
          newPath: newPath,
          extensionChanged: true,
          warning: removed
              ? null
              : 'Encrypted copy saved, but the original unencrypted file could '
                  'not be removed. Delete it manually.',
        );
      }

      // Case B: tab switched to plain, but file on disk is .scrb
      // → rename to .txt or .rtf (based on editor mode) and write unencrypted.
      if (!tab.isEncrypted && isScrbOnDisk) {
        final newExt = tab.mode == EditorMode.richText ? '.rtf' : '.txt';
        final newPath = _swapExtension(currentPath, newExt);
        if (!await overwriteAllowed(newPath)) {
          return SaveResult.failure(saveOverwriteDeclined);
        }
        if (newExt == '.rtf' && tab.deltaJson.isNotEmpty) {
          if (!await rtfWriteAllowed()) return SaveResult.failure('Cancelled');
          final written = tab.snapshotForSave();
          final rtf = RtfService.deltaToRtf(written.deltaJson);
          await _fileService.writeRtfFile(newPath, rtf);
          editor.markTabSavedAs(tab, newPath, written);
        } else {
          final wrote = await editor.saveActiveTabAs(newPath);
          if (!wrote) return SaveResult.failure('Tab is locked');
        }
        // Remove the now-orphaned encrypted original so a stale .scrb does not
        // linger alongside the decrypted file.
        await _deleteOldFile(currentPath, newPath);
        return SaveResult.success(newPath: newPath, extensionChanged: true);
      }

      // Case B2: editor mode no longer matches the on-disk format.
      // A rich-text tab over a plain file would write the scrib_rich envelope
      // into it (JSON garbage in every other editor); a plain-mode tab over a
      // .rtf would write a headerless file Word/WordPad reject. Swap the
      // extension, mirroring the encryption-toggle cases above.
      if (!tab.isEncrypted && !isScrbOnDisk) {
        if (isRichWithDelta && !isRtfOnDisk) {
          // Same order everywhere: confirm the destination first, then the
          // content loss.
          final newPath = _swapExtension(currentPath, '.rtf');
          if (!await overwriteAllowed(newPath)) {
            return SaveResult.failure(saveOverwriteDeclined);
          }
          if (!await rtfWriteAllowed()) return SaveResult.failure('Cancelled');
          final written = tab.snapshotForSave();
          final rtf = RtfService.deltaToRtf(written.deltaJson);
          await _fileService.writeRtfFile(newPath, rtf);
          editor.markTabSavedAs(tab, newPath, written);
          await _deleteOldFile(currentPath, newPath);
          return SaveResult.success(newPath: newPath, extensionChanged: true);
        }
        if (!isRichWithDelta && isRtfOnDisk) {
          final newPath = _swapExtension(currentPath, '.txt');
          if (!await overwriteAllowed(newPath)) {
            return SaveResult.failure(saveOverwriteDeclined);
          }
          final wrote = await editor.saveActiveTabAs(newPath);
          if (!wrote) return SaveResult.failure('Tab is locked');
          await _deleteOldFile(currentPath, newPath);
          return SaveResult.success(newPath: newPath, extensionChanged: true);
        }
      }

      // Case C: encrypted save to same path — password still required.
      if (tab.isEncrypted && tab.password == null) {
        if (passwordForNewEncryption == null) {
          return SaveResult.failure('Password required');
        }
        tab.password = passwordForNewEncryption;
      }

      // Case D: in-place save. RTF gets Delta→RTF conversion first.
      if (isRtfOnDisk && isRichWithDelta) {
        if (!await rtfWriteAllowed()) return SaveResult.failure('Cancelled');
        final written = tab.snapshotForSave();
        final rtf = RtfService.deltaToRtf(written.deltaJson);
        await _fileService.writeRtfFile(currentPath, rtf);
        editor.markTabSavedAs(tab, currentPath, written);
        return SaveResult.success();
      }
      final saved = await editor.saveActiveTab();
      if (!saved) return SaveResult.failure('Could not save');
      return SaveResult.success();
    } catch (e) {
      if (kDebugMode) debugPrint('Save failed: $e');
      return SaveResult.failure(e.toString());
    }
  }

  /// Save-as flow. Opens a file picker at the appropriate starting directory
  /// and dispatches to the right write path based on extension.
  ///
  /// [resolvePassword] is called when the chosen path is .scrb and the tab
  /// doesn't already have a password. Return null to cancel.
  ///
  /// [confirmLossyRtf] is asked before a Delta→RTF write whose Delta carries
  /// image/table embeds (RTF conversion drops them); false or null cancels.
  ///
  /// [onWillWrite] fires after the path and password are fully resolved,
  /// immediately before the write starts — the point where the UI should show
  /// its progress overlay for the (slow, key-deriving) encrypted write.
  Future<SaveResult> saveAs(
    EditorProvider editor, {
    required Future<String?> Function() resolvePassword,
    Future<bool> Function()? confirmLossyRtf,
    Future<bool> Function(String path)? confirmOverwrite,
    void Function(bool encrypted)? onWillWrite,
  }) async {
    final tab = editor.activeTab;
    if (tab == null) return SaveResult.failure('No active tab');
    if (tab.isLocked) return SaveResult.failure('Tab is locked');

    String extension;
    if (tab.isEncrypted) {
      extension = 'scrb';
    } else if (tab.mode == EditorMode.richText) {
      extension = 'rtf';
    } else {
      extension = 'txt';
    }
    final defaultName = tab.fileName.endsWith('.$extension')
        ? tab.fileName
        : '${tab.fileName.replaceAll(RegExp(r'\.[^.]+$'), '')}.$extension';

    String? initialDir;
    if (tab.filePath != null) {
      final sep = tab.filePath!.lastIndexOf(Platform.pathSeparator);
      if (sep > 0) initialDir = tab.filePath!.substring(0, sep);
    } else {
      final defaultLoc = _settings.defaultSaveLocation;
      if (defaultLoc.isNotEmpty) initialDir = defaultLoc;
    }

    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Save As',
      fileName: defaultName,
      initialDirectory: initialDir,
      type: FileType.custom,
      allowedExtensions: ['txt', 'scrb', 'rtf'],
    );
    if (path == null) return SaveResult.failure('Cancelled');

    // If the tab is encrypted, force a .scrb extension even if the user omitted it.
    final effectivePath = (tab.isEncrypted && !path.toLowerCase().endsWith('.scrb'))
        ? _swapExtension(path, '.scrb')
        : path;
    // The picker ran its native "replace?" check against `path`. When we
    // retarget to a .scrb the user never saw, that confirmation does not apply
    // to the file we are about to replace — ask again for the real destination.
    if (canonicalPath(effectivePath) != canonicalPath(path) &&
        await File(effectivePath).exists()) {
      if (confirmOverwrite == null || !await confirmOverwrite(effectivePath)) {
        return SaveResult.failure(saveOverwriteDeclined);
      }
    }
    final isEncrypted = effectivePath.toLowerCase().endsWith('.scrb');
    final isRtf = effectivePath.toLowerCase().endsWith('.rtf');

    String? password;
    if (isEncrypted) {
      password = tab.password ?? await resolvePassword();
      if (password == null) return SaveResult.failure('Cancelled');
    }

    final isRtfWrite =
        isRtf && tab.mode == EditorMode.richText && tab.deltaJson.isNotEmpty;
    if (isRtfWrite && deltaHasEmbeds(tab.deltaJson)) {
      // RTF conversion drops image/table embeds — never silently.
      final proceed = confirmLossyRtf != null && await confirmLossyRtf();
      if (!proceed) return SaveResult.failure('Cancelled');
    }

    // All dialogs are done — let the UI raise its progress overlay before the
    // slow encrypted write instead of after it (which showed nothing at all).
    onWillWrite?.call(isEncrypted);

    try {
      if (isRtfWrite) {
        final written = tab.snapshotForSave();
        final rtf = RtfService.deltaToRtf(written.deltaJson);
        await _fileService.writeRtfFile(effectivePath, rtf);
        editor.markTabSavedAs(tab, effectivePath, written);
      } else {
        final wrote = await editor.saveActiveTabAs(effectivePath,
            encrypted: isEncrypted, password: password);
        // saveActiveTabAs refuses when the tab got locked during the picker /
        // password dialogs; reporting success here would tell the user a copy
        // exists at a path nothing was written to.
        if (!wrote) return SaveResult.failure('Tab is locked');
      }
      return SaveResult.success(newPath: effectivePath);
    } catch (e) {
      if (kDebugMode) debugPrint('Save-as failed: $e');
      return SaveResult.failure(e.toString());
    }
  }

  /// Best-effort removal of the pre-swap original after an encrypt/decrypt that
  /// changed the extension. Never deletes when the path did not actually change.
  /// Returns true if the old file is gone (deleted or already absent).
  Future<bool> _deleteOldFile(String oldPath, String newPath) async {
    if (oldPath == newPath) return true;
    try {
      final f = File(oldPath);
      if (await f.exists()) await f.delete();
      return true;
    } catch (e) {
      if (kDebugMode) debugPrint('Could not remove old file $oldPath: $e');
      return false;
    }
  }

  /// Swap the file extension, handling files with or without an existing extension.
  static String _swapExtension(String path, String newExt) {
    final dot = path.lastIndexOf('.');
    final sep = path.lastIndexOf(Platform.pathSeparator);
    if (dot > sep && dot > 0) {
      return '${path.substring(0, dot)}$newExt';
    }
    return '$path$newExt';
  }
}
