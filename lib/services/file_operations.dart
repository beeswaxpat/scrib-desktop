import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import '../providers/editor_provider.dart';
import 'file_service.dart';
import 'rtf_service.dart';
import 'settings_service.dart';

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
  /// Handles the encryption-toggle extension swap (.scrb ↔ .txt/.rtf) and
  /// returns `extensionChanged: true` so the UI can notify the user.
  Future<SaveResult> saveActive(
    EditorProvider editor, {
    required String? passwordForNewEncryption,
  }) async {
    final tab = editor.activeTab;
    if (tab == null) return SaveResult.failure('No active tab');
    if (tab.filePath == null) return SaveResult.failure('Needs save-as');

    final currentPath = tab.filePath!;
    final isRtfOnDisk = currentPath.toLowerCase().endsWith('.rtf');
    final isScrbOnDisk = currentPath.toLowerCase().endsWith('.scrb');

    try {
      // Case A: tab switched to encrypted, but file on disk is .txt/.rtf
      // → rename to .scrb and encrypt.
      if (tab.isEncrypted && !isScrbOnDisk) {
        final newPath = _swapExtension(currentPath, '.scrb');
        if (tab.password == null && passwordForNewEncryption == null) {
          return SaveResult.failure('Password required');
        }
        tab.password ??= passwordForNewEncryption;
        await editor.saveActiveTabAs(newPath,
            encrypted: true, password: tab.password);
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
        if (newExt == '.rtf' && tab.deltaJson.isNotEmpty) {
          final rtf = RtfService.deltaToRtf(tab.deltaJson);
          await _fileService.writeRtfFile(newPath, rtf);
          editor.markTabSavedAs(newPath);
        } else {
          await editor.saveActiveTabAs(newPath);
        }
        // Remove the now-orphaned encrypted original so a stale .scrb does not
        // linger alongside the decrypted file.
        await _deleteOldFile(currentPath, newPath);
        return SaveResult.success(newPath: newPath, extensionChanged: true);
      }

      // Case C: encrypted save to same path — password still required.
      if (tab.isEncrypted && tab.password == null) {
        if (passwordForNewEncryption == null) {
          return SaveResult.failure('Password required');
        }
        tab.password = passwordForNewEncryption;
      }

      // Case D: in-place save. RTF gets Delta→RTF conversion first.
      if (isRtfOnDisk && tab.mode == EditorMode.richText && tab.deltaJson.isNotEmpty) {
        final rtf = RtfService.deltaToRtf(tab.deltaJson);
        await _fileService.writeRtfFile(currentPath, rtf);
        editor.markTabSavedAs(currentPath);
        return SaveResult.success();
      }
      await editor.saveActiveTab();
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
  Future<SaveResult> saveAs(
    EditorProvider editor, {
    required Future<String?> Function() resolvePassword,
  }) async {
    final tab = editor.activeTab;
    if (tab == null) return SaveResult.failure('No active tab');

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
    final isEncrypted = effectivePath.toLowerCase().endsWith('.scrb');
    final isRtf = effectivePath.toLowerCase().endsWith('.rtf');

    String? password;
    if (isEncrypted) {
      password = tab.password ?? await resolvePassword();
      if (password == null) return SaveResult.failure('Cancelled');
    }

    try {
      if (isRtf && tab.mode == EditorMode.richText && tab.deltaJson.isNotEmpty) {
        final rtf = RtfService.deltaToRtf(tab.deltaJson);
        await _fileService.writeRtfFile(effectivePath, rtf);
        editor.markTabSavedAs(effectivePath);
      } else {
        await editor.saveActiveTabAs(effectivePath,
            encrypted: isEncrypted, password: password);
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
