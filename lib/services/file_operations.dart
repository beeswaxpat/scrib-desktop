import 'dart:io';
import 'package:file_selector/file_selector.dart'
    show XTypeGroup, getSaveLocation;
import 'package:flutter/foundation.dart';
import '../providers/editor_provider.dart';
import 'atomic_write.dart' show AtomicWrite, canonicalPath;
import 'file_service.dart';
import 'rtf_service.dart';
import 'settings_service.dart';

/// Error string returned when the user declined to replace an existing file at
/// an extension-swap destination. Distinct from a plain 'Cancelled' so the UI
/// can tell the user nothing was saved: they pressed Ctrl+S and the tab is
/// still dirty (and, after Ctrl+E, still flagged encrypted over a plaintext
/// path), which is not obvious from the dialog alone.
const String saveOverwriteDeclined = 'Overwrite declined';

/// Error string returned when the file changed on disk since Scrib last read or
/// wrote it and the user chose not to replace the external edit.
const String saveExternalChangeDeclined = 'External change declined';

/// Error string returned when Save As targets a file another tab already has
/// open. Two tabs on one file overwrite each other on the next auto-save.
const String savePathAlreadyOpen = 'Already open in another tab';

/// Error string returned when the active tab changed while the Save As dialog
/// was open. The native dialog does not block the Scrib window.
const String saveTabSwitched = 'Active tab changed';

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

/// Shows the Save As dialog and returns the path the user chose, or null when
/// they cancelled. It only picks a path: nothing is written until [saveAs]
/// has run its checks.
typedef SaveLocationPicker = Future<String?> Function(
    String suggestedName, String? initialDirectory);

/// Coordinates open/save/save-as across plain text, rich text (RTF), and
/// encrypted (.scrb) formats. Stateless — all state lives on the tab.
class FileOperations {
  final FileService _fileService;
  final SettingsService _settings;
  final SaveLocationPicker _pickSaveLocation;

  /// [pickSaveLocation] replaces the native Save As dialog in tests.
  FileOperations(this._fileService, this._settings,
      {SaveLocationPicker? pickSaveLocation})
      : _pickSaveLocation = pickSaveLocation ?? _showSaveDialog;

  /// The Windows Save dialog (IFileSaveDialog through file_selector). It
  /// returns a path and never writes the file. It asks before replacing an
  /// existing file and appends no extension to a bare name, which is why
  /// [saveAsTarget] picks one.
  static Future<String?> _showSaveDialog(
      String suggestedName, String? initialDirectory) async {
    final location = await getSaveLocation(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Notes', extensions: ['txt', 'scrb', 'rtf']),
      ],
      initialDirectory: initialDirectory,
      suggestedName: suggestedName,
    );
    return location?.path;
  }

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
    Future<bool> Function(String path)? confirmExternalChange,
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

    // Delta→RTF conversion drops tables and images RTF cannot hold (SVG),
    // whose bytes live only inside the Delta. Never without the user's say-so.
    // One conversion per save, so what was checked is exactly what is written.
    Future<String?> rtfToWrite(SavedContent written) =>
        _rtfToWrite(written, confirmLossyRtf);

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

    // Another application changed this file since we last read or wrote it.
    // Background saves refuse outright; the manual path is the one place the
    // user can consciously choose to replace the external edit.
    bool ignoreDiskChange = false;
    if (await editor.diskChangedSince(tab)) {
      if (confirmExternalChange == null ||
          !await confirmExternalChange(currentPath)) {
        return SaveResult.failure(saveExternalChangeDeclined);
      }
      ignoreDiskChange = true;
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
        // Encrypt direction: the original is plaintext, so wipe it, not just unlink it.
        final removed = await _deleteOldFile(currentPath, newPath, shred: true);
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
          final written = tab.snapshotForSave();
          final rtf = await rtfToWrite(written);
          if (rtf == null) return SaveResult.failure('Cancelled');
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
          final written = tab.snapshotForSave();
          final rtf = await rtfToWrite(written);
          if (rtf == null) return SaveResult.failure('Cancelled');
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
        final written = tab.snapshotForSave();
        final rtf = await rtfToWrite(written);
        if (rtf == null) return SaveResult.failure('Cancelled');
        await _fileService.writeRtfFile(currentPath, rtf);
        editor.markTabSavedAs(tab, currentPath, written);
        return SaveResult.success();
      }
      final saved =
          await editor.saveActiveTab(ignoreDiskChange: ignoreDiskChange);
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

    final path = await _pickSaveLocation(defaultName, initialDir);
    if (path == null) return SaveResult.failure('Cancelled');

    // The tab's format decides the extension, whatever the user typed.
    final effectivePath = saveAsTarget(path,
        encrypted: tab.isEncrypted,
        rich: tab.mode == EditorMode.richText && tab.deltaJson.isNotEmpty);

    // Binding a second tab to a file another tab already holds means the next
    // auto-save pass writes both, and whichever runs second silently discards
    // the other tab's edits. Refuse before anything is written.
    if (editor.isPathOpenInOtherTab(effectivePath, tab)) {
      return SaveResult.failure(savePathAlreadyOpen);
    }

    // The picker ran its native "replace?" check against `path`. When we
    // retarget to a name the user never saw, that confirmation does not apply
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
    // Converted once, before the write: a confirm, if needed, is asked about
    // exactly the file that will be written.
    SavedContent? rtfWritten;
    String? rtf;
    if (isRtfWrite) {
      rtfWritten = tab.snapshotForSave();
      rtf = await _rtfToWrite(rtfWritten, confirmLossyRtf);
      if (rtf == null) return SaveResult.failure('Cancelled');
    }

    // saveActiveTabAs writes the ACTIVE tab: had the user switched tabs while
    // the dialog was open, another note's content would land in this file
    // (with this tab's password for a .scrb) and that tab would be rebound to
    // it. The Save dialog is modal to Scrib's window, which should rule a
    // switch out; this check stays as the backstop. Refuse.
    if (!identical(editor.activeTab, tab)) {
      return SaveResult.failure(saveTabSwitched);
    }

    // All dialogs are done — let the UI raise its progress overlay before the
    // slow encrypted write instead of after it (which showed nothing at all).
    onWillWrite?.call(isEncrypted);

    try {
      if (rtf != null && rtfWritten != null) {
        await _fileService.writeRtfFile(effectivePath, rtf);
        editor.markTabSavedAs(tab, effectivePath, rtfWritten);
      } else {
        final wrote = await editor.saveActiveTabAs(effectivePath,
            encrypted: isEncrypted, password: password);
        // saveActiveTabAs refuses when the tab got locked during the picker /
        // password dialogs; reporting success here would tell the user a copy
        // exists at a path nothing was written to.
        if (!wrote) return SaveResult.failure('Tab is locked');
      }
      return SaveResult.success(
          newPath: effectivePath, extensionChanged: effectivePath != path);
    } catch (e) {
      if (kDebugMode) debugPrint('Save-as failed: $e');
      return SaveResult.failure(e.toString());
    }
  }

  /// The RTF for [written], or null when the save should stop: the
  /// conversion would leave something out (a table, an image RTF cannot hold)
  /// and [confirmLossyRtf] is missing or the user declined.
  static Future<String?> _rtfToWrite(SavedContent written,
      Future<bool> Function()? confirmLossyRtf) async {
    final out = RtfService.exportDelta(written.deltaJson);
    if (!out.dropped) return out.rtf;
    if (confirmLossyRtf == null || !await confirmLossyRtf()) return null;
    return out.rtf;
  }

  /// The path Save As writes when the user picked [picked].
  ///
  /// The Windows save dialog adds no extension of its own, so a name typed
  /// without one ("Meeting notes") comes back with none. Rich text written
  /// there, or to a .txt, was refused by every write path (the scrib_rich
  /// envelope would be JSON in other editors) and the note was never saved.
  /// So the tab's format picks the container: encrypted goes to .scrb, rich
  /// text to .rtf, plain text to .txt. Picking .scrb for a plain tab still
  /// means "save an encrypted copy". A plain tab keeps any other extension
  /// the user typed (.md, .log), since plain text is valid in all of them.
  @visibleForTesting
  static String saveAsTarget(String picked,
      {required bool encrypted, required bool rich}) {
    // Windows drops trailing dots and spaces from file names, so "Meeting."
    // would be written as "Meeting" while the tab recorded "Meeting.".
    picked = picked.replaceFirst(RegExp(r'[. ]+$'), '');
    final ext = _extensionOf(picked);
    final String wanted;
    if (encrypted) {
      wanted = '.scrb';
    } else if (ext == '.scrb') {
      return picked;
    } else if (rich) {
      wanted = '.rtf';
    } else {
      if (ext.isNotEmpty && ext != '.rtf') return picked;
      wanted = '.txt';
    }
    if (ext == wanted) return picked;
    // Swap one of our own extensions; append to anything else, so a dotted
    // name like "Minutes 10.17" keeps its full stem.
    if (ext == '.txt' || ext == '.rtf' || ext == '.scrb') {
      return _swapExtension(picked, wanted);
    }
    return '$picked$wanted';
  }

  /// Lower-case extension of [path]'s file name including the dot, or '' when
  /// the name has none.
  static String _extensionOf(String path) {
    final sep = path.lastIndexOf(RegExp(r'[\\/]'));
    final name = path.substring(sep + 1);
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(dot).toLowerCase() : '';
  }

  /// Removal of the pre-swap original after an encrypt/decrypt that changed the
  /// extension. Never deletes when the path did not actually change.
  /// Returns true if the old file is gone (removed or already absent).
  ///
  /// When [shred] is true the bytes are overwritten before the file is
  /// unlinked. This is the encrypt direction: `File.delete()` only drops the
  /// directory entry, so without this the plaintext a user just "encrypted"
  /// stays readable in free space with an undelete tool, defeating AES-256
  /// without touching AES-256. Overwriting is best-effort by nature: on an SSD
  /// (wear levelling), a snapshotted volume, or a synced folder the original
  /// blocks may survive anyway, which is why the README tells users to create
  /// sensitive notes encrypted rather than converting them.
  ///
  /// Scrib's own staging and backup siblings are swept too: a `.scrib-bak` left
  /// by an interrupted fallback rename is a complete copy of the previous
  /// content, and on this path that content is the plaintext being removed.
  Future<bool> _deleteOldFile(String oldPath, String newPath,
      {bool shred = false}) async {
    if (canonicalPath(oldPath) == canonicalPath(newPath)) return true;
    var ok = true;
    try {
      final f = File(oldPath);
      if (await f.exists()) {
        if (shred) await _overwriteBytes(f);
        await f.delete();
      }
    } catch (e) {
      if (kDebugMode) debugPrint('Could not remove old file $oldPath: $e');
      ok = false;
    }
    for (final sibling in [
      '$oldPath${AtomicWrite.bakSuffix}',
      '$oldPath${AtomicWrite.tmpSuffix}',
    ]) {
      try {
        final s = File(sibling);
        if (await s.exists()) {
          if (shred) await _overwriteBytes(s);
          await s.delete();
        }
      } catch (e) {
        if (kDebugMode) debugPrint('Could not remove $sibling: $e');
        ok = false;
      }
    }
    return ok;
  }

  /// Overwrite [file]'s contents in place before it is unlinked. Writes through
  /// the same handle and flushes, so the filesystem reuses the existing blocks
  /// rather than allocating new ones the way a fresh write would.
  Future<void> _overwriteBytes(File file) async {
    final length = await file.length();
    if (length <= 0) return;
    final handle = await file.open(mode: FileMode.writeOnlyAppend);
    try {
      await handle.setPosition(0);
      const chunk = 64 * 1024;
      final zeros = Uint8List(chunk);
      var remaining = length;
      while (remaining > 0) {
        final n = remaining < chunk ? remaining : chunk;
        await handle.writeFrom(zeros, 0, n);
        remaining -= n;
      }
      await handle.flush();
    } finally {
      await handle.close();
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
