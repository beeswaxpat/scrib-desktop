import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../constants.dart';
import '../services/atomic_write.dart';
import '../services/file_service.dart';
import '../services/image_embed_service.dart';
import '../services/rtf_service.dart';
import '../services/settings_service.dart';
import '../services/table_embed.dart';

/// Editor mode for each tab
enum EditorMode { plainText, richText }

/// True when [deltaJson] contains any non-text insert op (image or table
/// embeds). RTF conversion drops those ops, so every Delta-to-RTF write path
/// must check this and warn (manual save) or defer (auto-save) instead of
/// silently discarding the embeds and marking the tab clean.
bool deltaHasEmbeds(String deltaJson) {
  if (deltaJson.isEmpty) return false;
  try {
    final ops = jsonDecode(deltaJson);
    if (ops is! List) return false;
    for (final op in ops) {
      if (op is Map && op['insert'] is! String) return true;
    }
    return false;
  } catch (_) {
    return false;
  }
}

/// Plain text for COUNTING and SEARCHING, extracted from Quill Delta JSON.
///
/// Unlike the mode-conversion extraction (which must stay byte-faithful to the
/// visible text), this keeps embed content visible to search and stats:
///  * table embeds contribute their cell text (cells separated by newlines so
///    a query can never falsely match across two adjacent cells);
///  * any other embed (image, unknown) becomes a single space so the words on
///    either side of an inline image are not fused into one.
///
/// The offsets in the returned string do NOT correspond to Quill document
/// positions — use it only where counts matter, never to target a replace.
/// Reusable by any surface that needs searchable/countable note text (per-tab
/// stats, global search, future previews).
String extractSearchableDeltaText(String deltaJson) {
  if (deltaJson.isEmpty) return '';
  try {
    final ops = jsonDecode(deltaJson);
    if (ops is! List) return '';
    final buffer = StringBuffer();
    for (final op in ops) {
      if (op is! Map || !op.containsKey('insert')) continue;
      final insert = op['insert'];
      if (insert is String) {
        buffer.write(insert);
      } else if (insert is Map) {
        final table = ScribTable.fromCustomEmbedData(insert['custom']);
        final cellText = table?.searchableCellText ?? '';
        buffer.write(cellText.isNotEmpty ? cellText : ' ');
      }
    }
    // Remove the trailing newline that Quill always adds.
    var result = buffer.toString();
    if (result.endsWith('\n')) {
      result = result.substring(0, result.length - 1);
    }
    return result;
  } catch (_) {
    return '';
  }
}

/// The exact content one write committed to disk, captured BEFORE the write
/// starts so that [EditorTab.markSaved] records what actually landed rather
/// than whatever the user has typed since.
///
/// LOAD-BEARING: a save is not instantaneous — an encrypted write is an
/// isolate spawn plus PBKDF2 key derivation plus two forced flushes, and the
/// auto-save timer repeats it every 30s. Marking a tab clean against its
/// *live* content silently discards everything typed during that window: the
/// dirty flag clears, the tab-title asterisk disappears, and the quit backstop
/// reports nothing pending. Every write path must thread its snapshot through
/// to markSaved so an edit made mid-write leaves the tab dirty and is
/// persisted by the next save.
class SavedContent {
  final EditorMode mode;
  final String plainText;
  final String deltaJson;

  const SavedContent({
    required this.mode,
    required this.plainText,
    required this.deltaJson,
  });

  /// The bytes this snapshot serializes to, mirroring
  /// [EditorTab.getSaveContent] but frozen at snapshot time.
  String get fileContent {
    if (mode == EditorMode.richText && deltaJson.isNotEmpty) {
      return '{"scrib_rich":$deltaJson}';
    }
    return plainText;
  }
}

/// Snapshot of a tab's content before a destructive operation (mode toggle).
/// Lets us offer the user a one-step revert if they toggled by mistake.
class EditorSnapshot {
  final EditorMode mode;
  final String plainText;
  final String deltaJson;

  const EditorSnapshot({
    required this.mode,
    required this.plainText,
    required this.deltaJson,
  });
}

/// Represents a single open file tab
class EditorTab {
  String? filePath;
  String fileName;
  String savedContent; // Last saved state (for dirty detection in plain text)
  bool isEncrypted;
  String? password; // Only kept in memory for .scrb files
  final TextEditingController controller;
  final UndoHistoryController undoController;
  int cursorLine;
  int cursorColumn;
  int? colorIndex; // Index into accentColors (null = no per-tab color)
  EditorMode mode;
  String deltaJson; // Current Quill Delta JSON (rich text mode)
  String savedDeltaJson; // Last saved Delta JSON (for dirty detection in rich text)
  String tabFontFamily; // Per-tab font family (plain text and rich text default)
  double tabFontSize;   // Per-tab font size

  /// A locked tab is a file-backed .scrb whose decrypted content and password
  /// are NOT in memory. It renders as a lock screen until the user re-enters
  /// the password (which routes through [EditorProvider.openScrbFile]).
  bool isLocked;

  /// On-disk identity as of the last read or successful write: modification
  /// time and size. Compared before a write to notice that another application
  /// changed the file underneath us (an editor, `git pull`, a cloud sync).
  /// Null means we have never stamped it, so there is nothing to compare and
  /// writes proceed. See [EditorProvider.diskChangedSince].
  DateTime? diskModified;
  int? diskLength;

  /// Last pre-mode-toggle snapshot. Consumed once by revertModeToggle() and
  /// cleared on any subsequent mode change or tab save.
  EditorSnapshot? _preToggleSnapshot;

  EditorTab({
    this.filePath,
    required this.fileName,
    String content = '',
    this.isEncrypted = false,
    this.password,
    this.cursorLine = 1,
    this.cursorColumn = 1,
    this.colorIndex,
    this.mode = EditorMode.plainText,
    this.deltaJson = '',
    this.savedDeltaJson = '',
    this.tabFontFamily = 'Calibri',
    this.tabFontSize = 14.0,
    this.isLocked = false,
  }) : savedContent = content,
       controller = TextEditingController(text: content),
       undoController = UndoHistoryController();

  bool get isDirty {
    if (mode == EditorMode.richText) {
      return deltaJson != savedDeltaJson;
    }
    return controller.text != savedContent;
  }

  String get displayName => isDirty ? '$fileName *' : fileName;

  /// Freeze the content a write is about to persist. Callers must take this
  /// BEFORE awaiting the write and pass it back to [markSaved].
  SavedContent snapshotForSave() => SavedContent(
        mode: mode,
        plainText: controller.text,
        deltaJson: deltaJson,
      );

  /// Record [written] — the content a completed write actually put on disk —
  /// as this tab's saved state.
  ///
  /// Takes the snapshot rather than re-reading the live controller, so an edit
  /// made while the write was in flight leaves the tab dirty instead of being
  /// silently marked saved and lost. If the mode changed mid-write, the tab
  /// also stays dirty: the marker is applied to the mode that was written, and
  /// the other mode's dirty comparison still fails.
  void markSaved(SavedContent written) {
    // A lock can land while a save is still in flight (the idle auto-lock runs
    // unattended, and an encrypted write takes >100ms). [written] holds the
    // DECRYPTED note, so applying it now would undo lock()'s wipe — seeding
    // plaintext back into a locked tab — and pin the tab permanently dirty,
    // since every save path refuses locked tabs and could never clean it
    // again. The bytes are already on disk; the lock stands.
    if (isLocked) return;
    if (written.mode == EditorMode.richText) {
      savedDeltaJson = written.deltaJson;
    } else {
      savedContent = written.plainText;
    }
    // A successful save invalidates any previous mode-toggle snapshot —
    // once committed to disk, the "pre-toggle" content is no longer something
    // we want to offer as a one-step revert.
    _preToggleSnapshot = null;
  }

  EditorSnapshot? get preToggleSnapshot => _preToggleSnapshot;

  /// Capture the current state before a destructive mode toggle.
  void capturePreToggleSnapshot() {
    _preToggleSnapshot = EditorSnapshot(
      mode: mode,
      plainText: controller.text,
      deltaJson: deltaJson,
    );
  }

  /// Apply a saved snapshot (used by EditorProvider.revertModeToggle).
  void applySnapshot(EditorSnapshot snap) {
    mode = snap.mode;
    controller.text = snap.plainText;
    deltaJson = snap.deltaJson;
    _preToggleSnapshot = null;
  }

  /// Whether this tab can be locked right now: it must be an encrypted file on
  /// disk, not already locked, and hold no unsaved changes that would be lost
  /// (a dirty tab is saved by [EditorProvider.lockTab] first, which needs the
  /// password to still be in memory).
  /// Whether the tab's on-disk file is actually an encrypted container.
  ///
  /// [isEncrypted] is an in-memory intent flag that Ctrl+E flips WITHOUT
  /// touching [filePath], so it can be true over a plaintext `.txt`. Anything
  /// that reasons about the file on disk must test the path, not the flag.
  bool get hasScrbPath => filePath != null && filePath!.toLowerCase().endsWith('.scrb');

  /// Whether this tab can be locked right now.
  ///
  /// Requires a real `.scrb` on disk: locking a tab that is merely FLAGGED
  /// encrypted over a plaintext file wipes the content and password, shows a
  /// lock screen, and then can never be unlocked, because unlock reads the
  /// path back through openScrbFile and the bytes there are not a .scrb. The
  /// UI would report "Encrypted" and then "Locked" over a file that is
  /// plaintext on disk.
  bool get canLock =>
      isEncrypted &&
      hasScrbPath &&
      !isLocked &&
      (!isDirty || password != null);

  /// Wipe the decrypted content and password from this tab's state and mark it
  /// locked. The caller is responsible for persisting unsaved changes first.
  void lock() {
    isLocked = true;
    password = null;
    controller.clear();
    savedContent = '';
    deltaJson = '';
    savedDeltaJson = '';
    _preToggleSnapshot = null;
    // The undo stack still holds every intermediate state of the decrypted
    // document; clearing the tab's text without clearing it would leave the
    // note reconstructable behind the lock screen with Ctrl+Z.
    undoController.value = UndoHistoryValue.empty;
  }

  /// Get the content to save (handles both modes)
  String getSaveContent() {
    if (mode == EditorMode.richText && deltaJson.isNotEmpty) {
      // Wrap delta in scrib_rich envelope for .scrb detection.
      // String concat avoids a full JSON decode + re-encode on every save.
      return '{"scrib_rich":$deltaJson}';
    }
    return controller.text;
  }

  void dispose() {
    controller.dispose();
    undoController.dispose();
    password = null;
    savedContent = '';
    deltaJson = '';
    savedDeltaJson = '';
  }
}

/// Manages all open editor tabs and file operations
class EditorProvider extends ChangeNotifier {
  final FileService _fileService;
  final SettingsService _settingsService;

  final List<EditorTab> _tabs = [];
  int _activeTabIndex = -1;

  // Search state
  bool _showSearch = false;
  bool _showReplace = false;
  bool _showGlobalSearch = false;
  String _pendingFindQuery = ''; // pre-populated when navigating from global search

  // Debounce timer for content changes
  Timer? _contentDebounce;
  static const _debounceDuration = Duration(milliseconds: 150);

  // Cached plain text for word/char/line counts (avoids re-parsing Delta per getter).
  String? _cachedActiveText;

  // Cached word/char/line counts, computed in ONE pass over the cached text so
  // the status bar's three getters never trigger three separate document scans.
  ({int words, int chars, int lines})? _cachedCounts;

  /// Invalidate the cached active-tab text and its derived counts together.
  void _invalidateActiveText() {
    _cachedActiveText = null;
    _cachedCounts = null;
  }

  // Auto-save timer — started/restarted whenever the interval setting changes.
  Timer? _autoSaveTimer;

  // Auto-lock: a coarse periodic check compares the last user activity against
  // the configured idle threshold and locks every lockable encrypted tab.
  Timer? _autoLockTimer;
  late DateTime _lastActivity;
  final Duration _autoLockPollInterval;

  /// Clock used for the auto-lock idle calculation. Injectable so tests can
  /// advance idle time deterministically; production always uses the default.
  final DateTime Function() _now;

  EditorProvider(
    this._fileService,
    this._settingsService, {
    @visibleForTesting DateTime Function()? now,
    @visibleForTesting Duration autoLockPollInterval = const Duration(seconds: 10),
  })  : _now = now ?? DateTime.now,
        _autoLockPollInterval = autoLockPollInterval {
    _lastActivity = _now();
    _settingsService.addListener(_onSettingsChanged);
    _updateAutoSave();
    _updateAutoLock();
    addNewTab();
  }

  void _onSettingsChanged() {
    _updateAutoSave();
    _updateAutoLock();
  }

  void _updateAutoSave() {
    _autoSaveTimer?.cancel();
    final interval = _settingsService.autoSaveInterval;
    if (interval > 0) {
      _autoSaveTimer = Timer.periodic(Duration(seconds: interval), (_) {
        _autoSaveAll();
      });
    }
  }

  void _updateAutoLock() {
    _autoLockTimer?.cancel();
    final minutes = _settingsService.autoLockMinutes;
    if (minutes > 0) {
      _autoLockTimer = Timer.periodic(_autoLockPollInterval, (_) {
        if (_now().difference(_lastActivity).inSeconds >= minutes * 60) {
          unawaited(lockAllEncrypted());
        }
      });
    }
  }

  /// Called by the UI on any pointer or key event so the auto-lock idle clock
  /// resets. Deliberately does NOT notify — it fires on every keystroke.
  void noteActivity() => _lastActivity = _now();

  Future<void> _autoSaveAll() async {
    await _saveDirtyFileBackedTabs();
  }

  /// Save every dirty tab that can be persisted without UI: it needs a
  /// [filePath] and, if encrypted, a password. Returns true once no dirty tabs
  /// remain (everything was saved). Untitled tabs and password-less encrypted
  /// tabs are intentionally left dirty so the caller (e.g. the quit flow) can
  /// refuse to discard them and route them through save-as instead.
  Future<bool> saveAllSaveable() async {
    await _saveDirtyFileBackedTabs();
    return !hasUnsavedChanges;
  }

  /// Shared write loop for auto-save and save-all. Writes each dirty,
  /// file-backed tab through the same extension-aware routing the manual save
  /// path uses, so a .rtf rich-text tab is converted to RTF rather than having
  /// its scrib_rich envelope written verbatim.
  Future<bool> _saveDirtyFileBackedTabs() async {
    bool saved = false;
    for (final tab in List.of(_tabs)) {
      if (!tab.isDirty || tab.filePath == null) continue;
      try {
        final written = await _saveTabToDisk(tab);
        if (written != null) {
          tab.markSaved(written);
          saved = true;
        }
      } catch (e) {
        // Background saves must never interrupt the user, but surfacing
        // failures in the debug console keeps disk-full / permission issues
        // from being completely invisible during development and bug triage.
        if (kDebugMode) {
          debugPrint('Save failed for ${tab.fileName}: $e');
        }
      }
    }
    if (saved) notifyListeners();
    return saved;
  }

  /// Write a single tab to its existing [filePath] using extension-aware
  /// routing: encrypted → .scrb, rich-text .rtf → Delta-to-RTF, otherwise
  /// plain text. Returns false (without writing) whenever the tab cannot be
  /// saved safely to the path it currently points at:
  ///
  ///  * no path, or the tab is locked;
  ///  * encrypted with no password in memory (never write plaintext into a
  ///    .scrb);
  ///  * the encryption flag mismatches the on-disk extension in EITHER
  ///    direction — plaintext must never land in a .scrb and ciphertext must
  ///    never land in a .txt/.rtf. This state is reachable via Ctrl+E, which
  ///    flips [EditorTab.isEncrypted] without touching [EditorTab.filePath];
  ///    only the manual save path (FileOperations.saveActive) performs the
  ///    extension swap, so background saves must refuse and stay dirty;
  ///  * a rich-text tab over a plain file (the scrib_rich envelope would
  ///    corrupt the .txt), or a plain-mode tab over a .rtf (a headerless .rtf
  ///    is rejected by Word/WordPad) — same manual-swap rule;
  ///  * a Delta with image/table embeds targeting a .rtf — RTF conversion
  ///    drops embeds, so the write is deferred to the manual (confirming)
  ///    save path.
  ///
  /// Refused tabs stay dirty, so the quit flow's saveAllSaveable backstop
  /// keeps refusing to discard them. Throws on I/O failure.
  /// Record [tab]'s on-disk identity. Call after every read and every
  /// successful write, so the next write can tell "unchanged since we last
  /// touched it" from "somebody else edited this".
  Future<void> stampDiskState(EditorTab tab) async {
    final path = tab.filePath;
    if (path == null) {
      tab.diskModified = null;
      tab.diskLength = null;
      return;
    }
    try {
      final stat = await File(path).stat();
      tab.diskModified = stat.modified;
      tab.diskLength = stat.size;
    } catch (_) {
      tab.diskModified = null;
      tab.diskLength = null;
    }
  }

  /// True when [tab]'s file changed on disk since [stampDiskState] last ran.
  ///
  /// Without this, a tab left open across a `git pull`, a OneDrive sync, or an
  /// edit in another editor is silently overwritten by the next auto-save:
  /// AtomicWrite replaces the file outright and leaves no `.scrib-bak`, so the
  /// external edit is gone with no warning. A missing file is NOT a change, as
  /// the write simply recreates it.
  Future<bool> diskChangedSince(EditorTab tab) async {
    final path = tab.filePath;
    final known = tab.diskModified;
    if (path == null || known == null) return false;
    try {
      final f = File(path);
      if (!await f.exists()) return false;
      final stat = await f.stat();
      return stat.modified != known || stat.size != tab.diskLength;
    } catch (_) {
      return false;
    }
  }

  /// Returns the [SavedContent] that reached disk, or null when the write was
  /// refused. Callers pass the result straight to [EditorTab.markSaved] so the
  /// tab is marked clean against the bytes written, not against content the
  /// user may have typed while the write was in flight.
  ///
  /// [ignoreDiskChange] is set only by the manual save path, after the user has
  /// been shown the external-modification prompt and chose to overwrite.
  Future<SavedContent?> _saveTabToDisk(EditorTab tab,
      {bool ignoreDiskChange = false}) async {
    final path = tab.filePath;
    if (path == null) return null;
    // A locked tab's in-memory content is empty by design — writing it would
    // destroy the encrypted file. Locked tabs are never saved.
    if (tab.isLocked) return null;
    // Somebody else changed this file since we last read or wrote it. Refuse
    // and stay dirty rather than replacing their edit; the manual save path
    // asks the user and retries with ignoreDiskChange.
    if (!ignoreDiskChange && await diskChangedSince(tab)) return null;
    final lower = path.toLowerCase();
    final isScrbPath = lower.endsWith('.scrb');
    // Snapshot first: every routing decision below and the bytes written must
    // agree with each other and with what markSaved records.
    final written = tab.snapshotForSave();
    final content = written.fileContent;

    if (tab.isEncrypted) {
      if (tab.password == null) return null;
      if (!isScrbPath) return null; // ciphertext only ever goes into .scrb
      await _fileService.writeScrbFile(path, content, tab.password!);
      await stampDiskState(tab);
      return written;
    }

    if (isScrbPath) return null; // plaintext never goes into a .scrb

    if (lower.endsWith('.rtf')) {
      if (written.mode != EditorMode.richText || written.deltaJson.isEmpty) {
        return null; // plain text into a .rtf produces a headerless file
      }
      if (deltaHasEmbeds(written.deltaJson)) {
        return null; // lossy write — needs the manual path's confirmation
      }
      await _fileService.writeRtfFile(
          path, RtfService.deltaToRtf(written.deltaJson));
      await stampDiskState(tab);
      return written;
    }

    if (written.mode == EditorMode.richText && written.deltaJson.isNotEmpty) {
      return null; // scrib_rich envelope would corrupt the plain file
    }

    await _fileService.writeTxtFile(path, content);
    await stampDiskState(tab);
    return written;
  }

  // Getters
  List<EditorTab> get tabs => _tabs;
  int get activeTabIndex => _activeTabIndex;
  EditorTab? get activeTab => _activeTabIndex >= 0 && _activeTabIndex < _tabs.length
      ? _tabs[_activeTabIndex]
      : null;
  bool get showSearch => _showSearch;
  bool get showReplace => _showReplace;
  bool get showGlobalSearch => _showGlobalSearch;
  String get pendingFindQuery => _pendingFindQuery;
  bool get hasUnsavedChanges => _tabs.any((tab) => tab.isDirty);

  // ── Tab locking ─────────────────────────────────────────────────────────

  /// Lock [tab]: persist any unsaved changes (requires the password to still
  /// be in memory), then wipe the decrypted content and password from the tab.
  /// Returns false if the tab is not lockable (see [EditorTab.canLock]).
  Future<bool> lockTab(EditorTab tab) async {
    if (!_tabs.contains(tab) || !tab.canLock) return false;
    if (tab.isDirty) {
      // canLock guarantees password != null here. A save failure of ANY kind
      // (refusal or I/O exception) must keep the tab unlocked: lock() wipes
      // the in-memory content, and the idle auto-lock timer runs unawaited,
      // so a throw here would both destroy unsaved edits and escape as an
      // unhandled async exception.
      try {
        final written = await _saveTabToDisk(tab);
        if (written == null) return false;
        tab.markSaved(written);
      } catch (e) {
        if (kDebugMode) {
          debugPrint('Pre-lock save failed for ${tab.fileName}: $e');
        }
        return false;
      }
      // The user can type while the pre-lock save is in flight (an encrypted
      // write takes well over 100ms, and the idle auto-lock fires unattended).
      // Those edits are NOT on disk, and lock() is about to wipe them, so
      // refuse the lock and let the next save pick them up.
      if (tab.isDirty) return false;
    }
    // Capture before the wipe so the clipboard check has something to match.
    final wasShowing = tab.mode == EditorMode.richText
        ? extractSearchableDeltaText(tab.deltaJson)
        : tab.controller.text;
    tab.lock();
    // Embedded images decode into a process-global LRU keyed by data URI, so
    // the decrypted picture bytes of the note we just locked would otherwise
    // stay in memory behind the lock screen. The cache is shared, so this
    // evicts other tabs' images too: they re-decode on next paint, which is
    // the right trade for a control whose whole purpose is to stop holding
    // decrypted content.
    ImageEmbedService.clearDecodeCache();
    unawaited(_purgeClipboardIfFrom(wasShowing));
    _invalidateActiveText();
    notifyListeners();
    return true;
  }

  /// Lock every lockable encrypted tab (manual "Lock All" and idle auto-lock).
  /// Returns the number of tabs that were locked.
  Future<int> lockAllEncrypted() async {
    int locked = 0;
    for (final tab in List.of(_tabs)) {
      if (await lockTab(tab)) locked++;
    }
    return locked;
  }

  /// Minimum clipboard length considered for the post-lock purge. Short strings
  /// ("the", a digit) appear inside almost any note, so matching on them would
  /// clear clipboard data that has nothing to do with Scrib.
  static const int _clipboardPurgeMinLength = 16;

  /// Clear the system clipboard if it holds a slice of [content].
  ///
  /// Locking wipes the decrypted note from the tab, but text the user copied
  /// out of it (a password, a key) stays on the clipboard and is one Ctrl+V
  /// away, which defeats the point of an idle auto-lock. Only an exact
  /// substring of the note just locked is cleared, and only above
  /// [_clipboardPurgeMinLength], so unrelated clipboard contents survive.
  ///
  /// Best-effort: there is no platform clipboard in headless tests, and the
  /// user may have copied from an app Scrib cannot see.
  Future<void> _purgeClipboardIfFrom(String content) async {
    if (content.length < _clipboardPurgeMinLength) return;
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text;
      if (text == null || text.length < _clipboardPurgeMinLength) return;
      if (!content.contains(text)) return;
      await Clipboard.setData(const ClipboardData(text: ''));
    } catch (e) {
      if (kDebugMode) debugPrint('Clipboard purge skipped: $e');
    }
  }

  /// Whether any open tab is currently lockable.
  bool get hasLockableTabs => _tabs.any((t) => t.canLock);

  /// Add a locked placeholder tab for an encrypted file WITHOUT prompting for
  /// its password (used by session restore). If the file is already open, the
  /// existing tab is activated instead.
  EditorTab addLockedTab(String path, {int? colorIndex}) {
    final existingIndex = _indexOfOpenPath(path);
    if (existingIndex != -1) {
      _activeTabIndex = existingIndex;
      notifyListeners();
      return _tabs[existingIndex];
    }

    final tab = EditorTab(
      filePath: path,
      fileName: _fileService.getFileName(path),
      isEncrypted: true,
      isLocked: true,
      colorIndex: colorIndex,
      tabFontFamily: _settingsService.fontFamily,
      tabFontSize: _settingsService.fontSize,
    );

    if (_tabs.length == 1 && activeTab != null &&
        activeTab!.filePath == null && !activeTab!.isDirty &&
        activeTab!.controller.text.isEmpty) {
      // Deferred disposal (closeTab's pattern): a synchronous dispose fires
      // controller notifications mid-update. The replaced tab is empty and
      // untitled, so nothing sensitive waits on the microtask.
      final replaced = _tabs[0];
      _tabs[0] = tab;
      _activeTabIndex = 0;
      Future.microtask(replaced.dispose);
    } else {
      _tabs.add(tab);
      _activeTabIndex = _tabs.length - 1;
    }

    _invalidateActiveText();
    notifyListeners();
    return tab;
  }

  /// Change the password on the active encrypted tab and re-encrypt the file
  /// on disk immediately (also persisting any unsaved edits). If the tab has
  /// no path yet, the new password simply applies to the next save.
  /// Returns false when the active tab cannot have its password changed.
  /// Re-encrypt the active tab's file under [newPassword].
  ///
  /// Two ordering rules, both load-bearing:
  ///
  /// 1. The path must already be a `.scrb`. This is the only writeScrbFile
  ///    caller outside [_saveTabToDisk], so without the check it is the one
  ///    place ciphertext can land in a `.txt` or `.rtf` (reachable via Ctrl+E,
  ///    which flips isEncrypted without touching filePath).
  /// 2. [EditorTab.password] is committed only AFTER the write succeeds. On a
  ///    throw the UI tells the user the change failed, so they keep using the
  ///    old password; if the tab had already taken the new one, the next save
  ///    would silently re-encrypt the file under a passphrase they were told
  ///    was not applied. There is no password recovery, so that permanently
  ///    locks them out of their own note.
  Future<bool> changeActivePassword(String newPassword) async {
    final tab = activeTab;
    if (tab == null || !tab.isEncrypted || tab.isLocked) return false;

    if (tab.filePath == null) {
      // No file yet: the new password simply applies to the first save.
      tab.password = newPassword;
      notifyListeners();
      return true;
    }
    if (!tab.hasScrbPath) return false; // ciphertext only ever goes into .scrb

    final written = tab.snapshotForSave();
    await _fileService.writeScrbFile(
        tab.filePath!, written.fileContent, newPassword);
    tab.password = newPassword;
    tab.markSaved(written);
    notifyListeners();
    return true;
  }

  // ── Session persistence ─────────────────────────────────────────────────

  /// Snapshot of the open file-backed tabs for session restore. Untitled tabs
  /// have no on-disk identity and are excluded (the quit flow already refuses
  /// to discard them while dirty). Only paths and tab colors are recorded —
  /// never content or passwords.
  List<Map<String, dynamic>> sessionSnapshot() => [
        for (final tab in _tabs)
          if (tab.filePath != null)
            {
              'path': tab.filePath,
              if (tab.colorIndex != null) 'color': tab.colorIndex,
            },
      ];

  /// Index of the active tab within [sessionSnapshot]'s entries (0 if the
  /// active tab is untitled and therefore not part of the snapshot).
  int get sessionActiveIndex {
    int idx = 0;
    for (int i = 0; i < _tabs.length; i++) {
      if (_tabs[i].filePath == null) continue;
      if (i == _activeTabIndex) return idx;
      idx++;
    }
    return 0;
  }

  /// Reopen the tabs recorded by the last quit. Plain and RTF files load
  /// directly; encrypted .scrb files come back as LOCKED tabs so launch never
  /// prompts for passwords and never holds decrypted content the user hasn't
  /// asked for. Missing or unreadable files are skipped. Returns the number of
  /// tabs restored.
  Future<int> restorePreviousSession() async {
    final entries = _settingsService.sessionTabs;
    if (entries.isEmpty) return 0;

    final savedActive = _settingsService.sessionActiveIndex;
    EditorTab? activeTarget;
    int restored = 0;

    for (int i = 0; i < entries.length; i++) {
      final entry = entries[i];
      final path = entry['path'];
      if (path is! String || path.isEmpty) continue;
      final color = entry['color'];
      try {
        // Lazy crash repair: a fallback rename interrupted mid-swap leaves the
        // file's content stranded at <path>.scrib-bak with no primary. Restore
        // it here rather than silently dropping the tab from the session.
        if (!await AtomicWrite.recoverFileIfNeeded(path)) continue;
        final ext = _fileService.getExtension(path).toLowerCase();
        EditorTab? opened;
        if (ext == '.scrb') {
          opened = addLockedTab(path, colorIndex: color is int ? color : null);
        } else if (ext == '.rtf') {
          final rtf = await _fileService.readRtfFile(path);
          await openRtfFile(path, RtfService.rtfToDelta(rtf));
          opened = activeTab;
        } else {
          await openFile(path);
          opened = activeTab;
        }
        if (opened != null && color is int) opened.colorIndex = color;
        if (i == savedActive) activeTarget = opened;
        restored++;
      } catch (_) {
        // A file that fails to restore must never block the rest of startup.
      }
    }

    if (activeTarget != null) {
      final idx = _tabs.indexOf(activeTarget);
      if (idx != -1) _activeTabIndex = idx;
    }
    if (restored > 0) {
      _invalidateActiveText();
      notifyListeners();
    }
    return restored;
  }

  // Tab management
  static const _months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];

  /// Generate a date-stamped default name: Untitled_16Feb26
  String _newTabName() {
    final now = DateTime.now();
    final base = 'Untitled_${now.day.toString().padLeft(2, '0')}${_months[now.month - 1]}${(now.year % 100).toString().padLeft(2, '0')}';
    // Check for duplicates, append counter if needed
    final existing = _tabs.map((t) => t.fileName).toSet();
    if (!existing.contains(base)) return base;
    int n = 2;
    while (existing.contains('$base $n')) {
      n++;
    }
    return '$base $n';
  }

  void addNewTab() {
    final tab = EditorTab(
      fileName: _newTabName(),
      tabFontFamily: _settingsService.fontFamily,
      tabFontSize: _settingsService.fontSize,
    );
    _tabs.add(tab);
    _activeTabIndex = _tabs.length - 1;
    _invalidateActiveText();
    notifyListeners();
  }

  void setActiveTab(int index) {
    if (index >= 0 && index < _tabs.length) {
      _activeTabIndex = index;
      _invalidateActiveText();
      notifyListeners();
    }
  }

  bool closeTab(int index) {
    if (index < 0 || index >= _tabs.length) return false;

    final tab = _tabs[index];

    // Clear sensitive data immediately — never defer this
    tab.password = null;
    tab.savedContent = '';
    tab.deltaJson = '';
    tab.savedDeltaJson = '';

    _tabs.removeAt(index);

    if (_tabs.isEmpty) {
      // Inline new-tab creation to avoid double notifyListeners
      final newTab = EditorTab(fileName: _newTabName());
      _tabs.add(newTab);
      _activeTabIndex = 0;
    } else if (_activeTabIndex >= _tabs.length) {
      _activeTabIndex = _tabs.length - 1;
    } else if (_activeTabIndex > index) {
      _activeTabIndex--;
    }

    _invalidateActiveText();
    notifyListeners();

    // Defer disposal — synchronous dispose fires notifyListeners() and stutters.
    Future.microtask(() {
      tab.controller.dispose();
      tab.undoController.dispose();
    });

    return true;
  }

  /// Batch-close the given tabs in a single notification. Clean tabs are removed
  /// and disposed; dirty tabs are left open and returned so the caller can route
  /// them through the unsaved-changes prompt individually. The previously-active
  /// tab stays active if it survives; otherwise the active index is clamped.
  /// At least one tab always remains (a fresh one is created if all were closed).
  List<EditorTab> closeTabs(Iterable<EditorTab> toClose) {
    final closeSet = toClose.toSet();
    if (closeSet.isEmpty) return const [];

    final activeTab = (_activeTabIndex >= 0 && _activeTabIndex < _tabs.length)
        ? _tabs[_activeTabIndex]
        : null;

    final survivors = <EditorTab>[];
    final removed = <EditorTab>[];
    final dirtyKept = <EditorTab>[];
    for (final tab in _tabs) {
      if (closeSet.contains(tab)) {
        if (tab.isDirty) {
          dirtyKept.add(tab);
          survivors.add(tab);
        } else {
          // Clear sensitive data immediately — never defer this.
          tab.password = null;
          tab.savedContent = '';
          tab.deltaJson = '';
          tab.savedDeltaJson = '';
          removed.add(tab);
        }
      } else {
        survivors.add(tab);
      }
    }

    if (removed.isEmpty) return dirtyKept;

    _tabs
      ..clear()
      ..addAll(survivors);

    if (_tabs.isEmpty) {
      _tabs.add(EditorTab(fileName: _newTabName()));
      _activeTabIndex = 0;
    } else {
      final keptActive = activeTab != null ? _tabs.indexOf(activeTab) : -1;
      _activeTabIndex = keptActive != -1 ? keptActive : _tabs.length - 1;
    }

    _invalidateActiveText();
    notifyListeners();

    // Defer disposal — synchronous dispose stutters the close frame.
    for (final tab in removed) {
      final controller = tab.controller;
      final undo = tab.undoController;
      Future.microtask(() {
        controller.dispose();
        undo.dispose();
      });
    }

    return dirtyKept;
  }

  /// Index of an already-open tab bound to the same physical file as [path],
  /// or -1. Uses canonical comparison so Windows case/separator variants of
  /// one file can never produce two tabs (two tabs on one file auto-save over
  /// each other, last writer wins, with no conflict warning).
  int _indexOfOpenPath(String path) {
    final canonical = canonicalPath(path);
    return _tabs.indexWhere(
        (t) => t.filePath != null && canonicalPath(t.filePath!) == canonical);
  }

  /// Whether a tab OTHER than [exclude] is already bound to [path].
  ///
  /// Two tabs on one file is a data-loss state, not a display quirk: both are
  /// dirty against their own copy, and the auto-save loop writes both in the
  /// same pass, so the second write silently discards the first tab's edits.
  /// Save As is the reachable route, since it takes an arbitrary path.
  bool isPathOpenInOtherTab(String path, EditorTab exclude) {
    final canonical = canonicalPath(path);
    return _tabs.any((t) =>
        !identical(t, exclude) &&
        t.filePath != null &&
        canonicalPath(t.filePath!) == canonical);
  }

  // File operations
  Future<void> openFile(String path) async {
    // Check if already open
    final existingIndex = _indexOfOpenPath(path);
    if (existingIndex != -1) {
      _activeTabIndex = existingIndex;
      notifyListeners();
      return;
    }

    final extension = _fileService.getExtension(path);
    final fileName = _fileService.getFileName(path);

    if (extension == '.scrb') {
      // Encrypted file - caller must use openScrbFile with password instead
      throw ScribNeedsPasswordException(path, fileName);
    }

    // Plain text file. Detect a scrib_rich envelope (written by older builds
    // whose save paths sent rich content to .txt files verbatim) and hydrate
    // a rich tab, exactly like openScrbFile — this transparently recovers
    // files already written that way instead of showing the user raw JSON.
    final content = await _fileService.readTxtFile(path);
    EditorMode mode = EditorMode.plainText;
    String plainContent = content;
    String deltaJson = '';
    if (content.startsWith(scribRichPrefix)) {
      try {
        final parsed = jsonDecode(content) as Map<String, dynamic>;
        final rich = parsed['scrib_rich'];
        if (rich is List) {
          deltaJson = jsonEncode(rich);
          plainContent = _extractPlainTextFromDelta(deltaJson);
          mode = EditorMode.richText;
        }
      } catch (_) {
        // Not a valid envelope after all — treat as ordinary plain text.
        mode = EditorMode.plainText;
        plainContent = content;
        deltaJson = '';
      }
    }
    final tab = EditorTab(
      filePath: path,
      fileName: fileName,
      content: plainContent,
      mode: mode,
      deltaJson: deltaJson,
      savedDeltaJson: deltaJson,
      tabFontFamily: _settingsService.fontFamily,
      tabFontSize: _settingsService.fontSize,
    );

    // Replace current tab if it's empty untitled
    if (_tabs.length == 1 && activeTab != null &&
        activeTab!.filePath == null && !activeTab!.isDirty &&
        activeTab!.controller.text.isEmpty) {
      // Deferred disposal (closeTab's pattern): a synchronous dispose fires
      // controller notifications mid-update. The replaced tab is empty and
      // untitled, so nothing sensitive waits on the microtask.
      final replaced = _tabs[0];
      _tabs[0] = tab;
      Future.microtask(replaced.dispose);
    } else {
      _tabs.add(tab);
      _activeTabIndex = _tabs.length - 1;
    }

    await stampDiskState(tab);
    await _settingsService.addRecentFile(path);
    _invalidateActiveText();
    notifyListeners();
  }

  /// Open a .rtf file (already parsed to Delta JSON by caller)
  Future<void> openRtfFile(String path, String deltaJson) async {
    // Check if already open
    final existingIndex = _indexOfOpenPath(path);
    if (existingIndex != -1) {
      _activeTabIndex = existingIndex;
      notifyListeners();
      return;
    }

    final fileName = _fileService.getFileName(path);
    final plainText = _extractPlainTextFromDelta(deltaJson);

    final tab = EditorTab(
      filePath: path,
      fileName: fileName,
      content: plainText,
      mode: EditorMode.richText,
      deltaJson: deltaJson,
      savedDeltaJson: deltaJson,
      tabFontFamily: _settingsService.fontFamily,
      tabFontSize: _settingsService.fontSize,
    );

    // Replace current tab if it's empty untitled
    if (_tabs.length == 1 && activeTab != null &&
        activeTab!.filePath == null && !activeTab!.isDirty &&
        activeTab!.controller.text.isEmpty) {
      // Deferred disposal (closeTab's pattern): a synchronous dispose fires
      // controller notifications mid-update. The replaced tab is empty and
      // untitled, so nothing sensitive waits on the microtask.
      final replaced = _tabs[0];
      _tabs[0] = tab;
      Future.microtask(replaced.dispose);
    } else {
      _tabs.add(tab);
      _activeTabIndex = _tabs.length - 1;
    }

    await stampDiskState(tab);
    await _settingsService.addRecentFile(path);
    _invalidateActiveText();
    notifyListeners();
  }

  /// Open a .scrb file with password
  Future<bool> openScrbFile(String path, String password) async {
    final content = await _fileService.readScrbFile(path, password);
    if (content == null) return false;

    final fileName = _fileService.getFileName(path);

    // Detect rich text content
    EditorMode mode = EditorMode.plainText;
    String plainContent = content;
    String deltaJson = '';
    if (content.startsWith(scribRichPrefix)) {
      mode = EditorMode.richText;
      try {
        final parsed = jsonDecode(content) as Map<String, dynamic>;
        deltaJson = jsonEncode(parsed['scrib_rich']);
        // Extract plain text for the TextEditingController fallback
        plainContent = _extractPlainTextFromDelta(deltaJson);
      } catch (_) {
        // If parsing fails, treat as plain text
        mode = EditorMode.plainText;
      }
    }

    // Find existing placeholder tab or create new
    final existingIndex = _indexOfOpenPath(path);
    if (existingIndex != -1) {
      final tab = _tabs[existingIndex];
      // An unlocked tab with unsaved edits must never be silently reloaded
      // from disk: re-opening the same file (Recent Files, Open, drag-drop)
      // would discard everything typed since the last save. Activate it and
      // keep the in-memory state. Locked placeholders are never dirty (lock()
      // wipes all content), so the unlock flow still refreshes below.
      if (!tab.isLocked && tab.isDirty) {
        _activeTabIndex = existingIndex;
        _invalidateActiveText();
        notifyListeners();
        return true;
      }
      tab.controller.text = plainContent;
      tab.savedContent = plainContent;
      // The file on disk is encrypted — the tab MUST be flagged encrypted, or a
      // subsequent save writes the decrypted plaintext back out unencrypted.
      tab.isEncrypted = true;
      tab.isLocked = false; // successful decrypt unlocks a locked placeholder
      tab.fileName = fileName;
      tab.password = password;
      tab.mode = mode;
      tab.deltaJson = deltaJson;
      tab.savedDeltaJson = deltaJson;
      await stampDiskState(tab);
      _activeTabIndex = existingIndex;
    } else {
      final tab = EditorTab(
        filePath: path,
        fileName: fileName,
        content: plainContent,
        isEncrypted: true,
        password: password,
        mode: mode,
        deltaJson: deltaJson,
        savedDeltaJson: deltaJson,
        tabFontFamily: _settingsService.fontFamily,
        tabFontSize: _settingsService.fontSize,
      );

      if (_tabs.length == 1 && activeTab != null &&
          activeTab!.filePath == null && !activeTab!.isDirty &&
          activeTab!.controller.text.isEmpty) {
        // Deferred disposal (closeTab's pattern): a synchronous dispose fires
        // controller notifications mid-update. The replaced tab is empty and
        // untitled, so nothing sensitive waits on the microtask.
        final replaced = _tabs[0];
        _tabs[0] = tab;
        _activeTabIndex = 0;
        Future.microtask(replaced.dispose);
      } else {
        _tabs.add(tab);
        _activeTabIndex = _tabs.length - 1;
      }
      await stampDiskState(tab);
    }

    await _settingsService.addRecentFile(path);
    _invalidateActiveText();
    notifyListeners();
    return true;
  }

  /// Save the active tab in place. Delegates to [_saveTabToDisk] so every
  /// caller gets the same refusal + extension-aware routing as auto-save
  /// (an extension-blind write here previously let the close-tab Save flow
  /// put plaintext into a .scrb and the scrib_rich envelope into a .rtf).
  /// Returns false when the tab needs Save As or the write was refused.
  Future<bool> saveActiveTab({bool ignoreDiskChange = false}) async {
    final tab = activeTab;
    if (tab == null || tab.isLocked) return false;

    if (tab.filePath == null) {
      return false; // Need "Save As" - caller should handle
    }

    final written = await _saveTabToDisk(tab, ignoreDiskChange: ignoreDiskChange);
    if (written == null) return false;
    tab.markSaved(written);
    notifyListeners();
    return true;
  }

  /// Save the active tab to a specific path
  Future<bool> saveActiveTabAs(String path, {bool encrypted = false, String? password}) async {
    final tab = activeTab;
    if (tab == null || tab.isLocked) return false;

    final written = tab.snapshotForSave();
    final content = written.fileContent;
    final lower = path.toLowerCase();

    // Same container rules the background path enforces, applied here too:
    // this is the OTHER entry point that writes a caller-chosen path (Save As,
    // the extension swaps, the untitled-tab rename), and it previously took
    // whatever it was handed. Ciphertext must land only in a .scrb, and a rich
    // Delta must not be written verbatim into a .txt, where the scrib_rich
    // envelope shows up as JSON in every other editor.
    if (encrypted && password != null) {
      if (!lower.endsWith('.scrb')) return false;
      await _fileService.writeScrbFile(path, content, password);
      tab.isEncrypted = true;
      tab.password = password;
    } else {
      if (lower.endsWith('.scrb')) return false; // plaintext never into a .scrb
      if (written.mode == EditorMode.richText &&
          written.deltaJson.isNotEmpty &&
          !lower.endsWith('.rtf')) {
        return false; // caller must convert to RTF or keep the .scrb
      }
      // RTF saves are handled by the caller (main_screen via RtfService) before
      // this method is called, so plain writeTxtFile is correct for all remaining cases.
      await _fileService.writeTxtFile(path, content);
      tab.isEncrypted = false;
      tab.password = null;
    }

    tab.filePath = path;
    tab.fileName = _fileService.getFileName(path);
    await stampDiskState(tab);
    tab.markSaved(written);
    await _settingsService.addRecentFile(path);
    notifyListeners();
    return true;
  }

  /// Mark [tab] as saved to a new path (used for RTF save, where the caller
  /// performed the Delta-to-RTF conversion and the write itself).
  ///
  /// [written] must be the snapshot the caller took BEFORE converting and
  /// writing, so an edit made during the write leaves the tab dirty rather
  /// than being marked saved against bytes that never landed.
  ///
  /// [tab] is passed explicitly rather than read from [activeTab]: the caller
  /// awaits dialogs and the write itself, and the user can switch tabs during
  /// those awaits. Resolving the target here would retarget whatever tab is
  /// active NOW at the written path and record ANOTHER tab's content against
  /// it — corrupting the dirty state of both. A tab that was closed mid-write
  /// is no longer in [_tabs] and is skipped.
  ///
  /// Recent-files update is fire-and-forget — not waiting on Hive before
  /// notifying listeners keeps the UI snappy on save.
  void markTabSavedAs(EditorTab tab, String path, SavedContent written) {
    // The isLocked guard keeps the "every save path refuses locked tabs"
    // invariant local: without it, a caller reaching this on a locked tab
    // would silently convert it into an "unencrypted, saved" tab.
    if (!_tabs.contains(tab) || tab.isLocked) return;
    tab.filePath = path;
    tab.fileName = _fileService.getFileName(path);
    tab.isEncrypted = false;
    tab.password = null;
    tab.markSaved(written);
    unawaited(stampDiskState(tab));
    unawaited(_settingsService.addRecentFile(path));
    notifyListeners();
  }

  /// Toggle encryption on active tab
  void toggleEncryption() {
    final tab = activeTab;
    if (tab == null || tab.isLocked) return;
    tab.isEncrypted = !tab.isEncrypted;
    if (!tab.isEncrypted) {
      tab.password = null;
    }
    notifyListeners();
  }

  // Per-tab color
  void setTabColor(int? index) {
    final tab = activeTab;
    if (tab == null) return;
    tab.colorIndex = index;
    notifyListeners();
  }

  // Per-tab font family (plain text and rich text default body font)
  void setTabFontFamily(String family) {
    final tab = activeTab;
    if (tab == null) return;
    tab.tabFontFamily = family;
    notifyListeners();
  }

  // Per-tab font size
  void setTabFontSize(double size) {
    final tab = activeTab;
    if (tab == null) return;
    tab.tabFontSize = size.clamp(minFontSize, maxFontSize);
    notifyListeners();
  }

  /// Toggle between plain text and rich text mode.
  /// Captures a one-step revert snapshot before any destructive conversion.
  void toggleEditorMode() {
    final tab = activeTab;
    if (tab == null || tab.isLocked) return;

    // Snapshot before changing anything so revertModeToggle() can restore it.
    tab.capturePreToggleSnapshot();

    if (tab.mode == EditorMode.plainText) {
      // Plain → Rich: Convert current text to unstyled Delta
      final text = tab.controller.text;
      if (text.isNotEmpty) {
        final delta = [
          {'insert': '$text\n'}
        ];
        tab.deltaJson = jsonEncode(delta);
      } else {
        tab.deltaJson = jsonEncode([{'insert': '\n'}]);
      }
      tab.savedDeltaJson = ''; // Mark as dirty so user saves in new format
      tab.mode = EditorMode.richText;
    } else {
      // Rich → Plain: Extract plain text, discard formatting
      final plainText = _extractPlainTextFromDelta(tab.deltaJson);
      tab.controller.text = plainText;
      tab.savedContent = ''; // Mark as dirty
      tab.deltaJson = '';
      tab.savedDeltaJson = '';
      tab.mode = EditorMode.plainText;
    }

    _invalidateActiveText();
    notifyListeners();
  }

  /// Revert the most recent mode toggle. Returns true if a revert was applied.
  bool revertModeToggle() {
    final tab = activeTab;
    if (tab == null) return false;
    final snap = tab.preToggleSnapshot;
    if (snap == null) return false;
    tab.applySnapshot(snap);
    _invalidateActiveText();
    notifyListeners();
    return true;
  }

  /// Update the delta JSON for the active tab (called by QuillEditor widget)
  void updateDeltaJson(String json) {
    final tab = activeTab;
    if (tab == null || tab.isLocked) return;
    // The Quill controller notifies on selection-only changes too (every
    // cursor move / click). When the serialized document is unchanged there
    // is nothing to store, so skip the cache invalidation and the debounced
    // notify: word/char/line counts must not be recomputed and the whole
    // listener tree must not rebuild just because the caret moved.
    if (json == tab.deltaJson) return;
    tab.deltaJson = json;
    // Debounced notify for dirty indicator
    onContentChanged();
  }

  /// Extract plain text from Quill Delta JSON
  String _extractPlainTextFromDelta(String deltaJson) {
    if (deltaJson.isEmpty) return '';
    try {
      final ops = jsonDecode(deltaJson) as List<dynamic>;
      final buffer = StringBuffer();
      for (final op in ops) {
        if (op is Map && op.containsKey('insert')) {
          final insert = op['insert'];
          if (insert is String) {
            buffer.write(insert);
          }
        }
      }
      // Remove trailing newline that Quill always adds
      var result = buffer.toString();
      if (result.endsWith('\n')) {
        result = result.substring(0, result.length - 1);
      }
      return result;
    } catch (_) {
      return '';
    }
  }

  // Tab rename (display name only)
  void renameTab(int index, String newName) {
    if (index < 0 || index >= _tabs.length) return;
    _tabs[index].fileName = newName;
    notifyListeners();
  }

  // Update tab file path after a file rename on disk
  void updateTabFile(int index, String newPath) {
    if (index < 0 || index >= _tabs.length) return;
    _tabs[index].filePath = newPath;
    _tabs[index].fileName = _fileService.getFileName(newPath);
    notifyListeners();
  }

  // ── Per-tab Find / Find & Replace ──────────────────────────────────────────

  /// Ctrl+F — open Find bar (no replace row).
  void openFind() {
    _showSearch = true;
    _showReplace = false;
    _showGlobalSearch = false;
    notifyListeners();
  }

  /// Ctrl+H — open Find & Replace bar.
  void openFindReplace() {
    _showSearch = true;
    _showReplace = true;
    _showGlobalSearch = false;
    notifyListeners();
  }

  /// Toggle replace row while find bar is already open.
  void toggleReplace() {
    if (!_showSearch) return;
    _showReplace = !_showReplace;
    notifyListeners();
  }

  void closeSearch() {
    _showSearch = false;
    _showReplace = false;
    _pendingFindQuery = '';
    notifyListeners();
  }

  /// Called from Escape or close button.
  void toggleSearch() {
    if (_showSearch) {
      closeSearch();
    } else {
      openFind();
    }
  }

  /// Navigate from global search: pre-populate find bar and switch tab.
  void openFindWithQuery(String query) {
    _pendingFindQuery = query;
    _showSearch = true;
    _showReplace = false;
    _showGlobalSearch = false;
    notifyListeners();
  }

  /// Called by ScribSearchBar in initState after it reads the pending query.
  void clearPendingFindQuery() {
    _pendingFindQuery = '';
  }

  // ── Global search (across all open tabs) ────────────────────────────────────

  void toggleGlobalSearch() {
    _showGlobalSearch = !_showGlobalSearch;
    if (_showGlobalSearch) {
      // Close per-tab find bar when global search opens.
      _showSearch = false;
      _showReplace = false;
    }
    notifyListeners();
  }

  /// Debounced content-change handler. Invalidates cached text and notifies.
  void onContentChanged() {
    _contentDebounce?.cancel();
    _contentDebounce = Timer(_debounceDuration, () {
      _invalidateActiveText();
      notifyListeners();
    });
  }

  /// Force immediate cache invalidation without waiting for the debounce.
  /// Used after operations that directly mutate controller text (replace-all)
  /// so word/char/line counts don't lag behind the visible content.
  void invalidateTextCache() {
    _invalidateActiveText();
    _contentDebounce?.cancel();
    notifyListeners();
  }

  String get _activeText {
    if (_cachedActiveText != null) return _cachedActiveText!;
    final tab = activeTab;
    if (tab == null) return _cachedActiveText = '';
    if (tab.mode == EditorMode.richText) {
      // Table-aware extraction: cell text participates in counts and search
      // (an image contributes a single space so it never fuses two words).
      return _cachedActiveText = extractSearchableDeltaText(tab.deltaJson);
    }
    return _cachedActiveText = tab.controller.text;
  }

  ({int words, int chars, int lines}) get _counts =>
      _cachedCounts ??= computeTextCounts(_activeText);

  /// Single pass over [text]: counts runs of non-whitespace (words), total
  /// length (chars) and newlines + 1 (lines). The whitespace class mirrors
  /// RegExp's \s, so the numbers are identical to the previous
  /// RegExp(r'\S+') / '\n'.allMatches implementations without allocating a
  /// Match object per word on every status-bar rebuild.
  @visibleForTesting
  static ({int words, int chars, int lines}) computeTextCounts(String text) {
    if (text.isEmpty) return (words: 0, chars: 0, lines: 1);
    var words = 0;
    var lines = 1;
    var inWord = false;
    for (var i = 0; i < text.length; i++) {
      final c = text.codeUnitAt(i);
      if (c == 0x0A) lines++;
      if (_isCountWhitespace(c)) {
        inWord = false;
      } else if (!inWord) {
        inWord = true;
        words++;
      }
    }
    return (words: words, chars: text.length, lines: lines);
  }

  /// ECMAScript \s (the class RegExp(r'\S+') negates): ASCII whitespace,
  /// line/paragraph separators, and the Unicode Zs space separators.
  static bool _isCountWhitespace(int c) =>
      (c >= 0x09 && c <= 0x0D) ||
      c == 0x20 ||
      c == 0xA0 ||
      c == 0x1680 ||
      (c >= 0x2000 && c <= 0x200A) ||
      c == 0x2028 ||
      c == 0x2029 ||
      c == 0x202F ||
      c == 0x205F ||
      c == 0x3000 ||
      c == 0xFEFF;

  int get wordCount => _counts.words;

  int get charCount => _counts.chars;

  int get lineCount => _counts.lines;

  /// Plain text content of the active tab for searching.
  /// Works in both plain text and rich text mode.
  String get searchableText => _activeText;

  @override
  void dispose() {
    _settingsService.removeListener(_onSettingsChanged);
    _autoSaveTimer?.cancel();
    _autoLockTimer?.cancel();
    _contentDebounce?.cancel();
    for (final tab in _tabs) {
      tab.dispose();
    }
    super.dispose();
  }
}

/// Thrown when openFile encounters a .scrb file that needs a password
class ScribNeedsPasswordException implements Exception {
  final String path;
  final String fileName;
  ScribNeedsPasswordException(this.path, this.fileName);
}
