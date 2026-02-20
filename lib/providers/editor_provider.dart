import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import '../constants.dart';
import '../services/file_service.dart';
import '../services/settings_service.dart';

/// Editor mode for each tab
enum EditorMode { plainText, richText }

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

  void markSaved() {
    if (mode == EditorMode.richText) {
      savedDeltaJson = deltaJson;
    } else {
      savedContent = controller.text;
    }
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

  // Debounce timer for content changes
  Timer? _contentDebounce;
  static const _debounceDuration = Duration(milliseconds: 150);

  // Cached plain text for word/char/line counts.
  // Invalidated whenever the active content or active tab changes.
  // This avoids re-parsing Delta JSON 3× per status-bar rebuild in rich text mode.
  String? _cachedActiveText;

  // Auto-save timer — started/restarted whenever the interval setting changes.
  Timer? _autoSaveTimer;

  EditorProvider(this._fileService, this._settingsService) {
    _settingsService.addListener(_onSettingsChanged);
    _updateAutoSave();
    addNewTab();
  }

  void _onSettingsChanged() => _updateAutoSave();

  void _updateAutoSave() {
    _autoSaveTimer?.cancel();
    final interval = _settingsService.autoSaveInterval;
    if (interval > 0) {
      _autoSaveTimer = Timer.periodic(Duration(seconds: interval), (_) {
        _autoSaveAll();
      });
    }
  }

  Future<void> _autoSaveAll() async {
    bool saved = false;
    for (final tab in List.of(_tabs)) {
      if (!tab.isDirty || tab.filePath == null) continue;
      try {
        final content = tab.getSaveContent();
        if (tab.isEncrypted && tab.password != null) {
          await _fileService.writeScrbFile(tab.filePath!, content, tab.password!);
        } else {
          await _fileService.writeTxtFile(tab.filePath!, content);
        }
        tab.markSaved();
        saved = true;
      } catch (_) {
        // Silent fail — auto-save should never interrupt the user
      }
    }
    if (saved) notifyListeners();
  }

  // Getters
  List<EditorTab> get tabs => _tabs;
  int get activeTabIndex => _activeTabIndex;
  EditorTab? get activeTab => _activeTabIndex >= 0 && _activeTabIndex < _tabs.length
      ? _tabs[_activeTabIndex]
      : null;
  bool get showSearch => _showSearch;
  bool get hasUnsavedChanges => _tabs.any((tab) => tab.isDirty);

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
    _cachedActiveText = null;
    notifyListeners();
  }

  void setActiveTab(int index) {
    if (index >= 0 && index < _tabs.length) {
      _activeTabIndex = index;
      _cachedActiveText = null;
      notifyListeners();
    }
  }

  bool closeTab(int index) {
    if (index < 0 || index >= _tabs.length) return false;

    final tab = _tabs[index];
    tab.dispose();
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

    _cachedActiveText = null;
    notifyListeners();
    return true;
  }

  // File operations
  Future<void> openFile(String path) async {
    // Check if already open
    final existingIndex = _tabs.indexWhere((t) => t.filePath == path);
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

    // Plain text file
    final content = await _fileService.readTxtFile(path);
    final tab = EditorTab(
      filePath: path,
      fileName: fileName,
      content: content,
      tabFontFamily: _settingsService.fontFamily,
      tabFontSize: _settingsService.fontSize,
    );

    // Replace current tab if it's empty untitled
    if (_tabs.length == 1 && activeTab != null &&
        activeTab!.filePath == null && !activeTab!.isDirty &&
        activeTab!.controller.text.isEmpty) {
      _tabs[0].dispose();
      _tabs[0] = tab;
    } else {
      _tabs.add(tab);
      _activeTabIndex = _tabs.length - 1;
    }

    await _settingsService.addRecentFile(path);
    _cachedActiveText = null;
    notifyListeners();
  }

  /// Open a .rtf file (already parsed to Delta JSON by caller)
  void openRtfFile(String path, String deltaJson) {
    // Check if already open
    final existingIndex = _tabs.indexWhere((t) => t.filePath == path);
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
      _tabs[0].dispose();
      _tabs[0] = tab;
    } else {
      _tabs.add(tab);
      _activeTabIndex = _tabs.length - 1;
    }

    _settingsService.addRecentFile(path);
    _cachedActiveText = null;
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
    final existingIndex = _tabs.indexWhere((t) => t.filePath == path);
    if (existingIndex != -1) {
      final tab = _tabs[existingIndex];
      tab.controller.text = plainContent;
      tab.savedContent = plainContent;
      tab.password = password;
      tab.mode = mode;
      tab.deltaJson = deltaJson;
      tab.savedDeltaJson = deltaJson;
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
        _tabs[0].dispose();
        _tabs[0] = tab;
        _activeTabIndex = 0;
      } else {
        _tabs.add(tab);
        _activeTabIndex = _tabs.length - 1;
      }
    }

    await _settingsService.addRecentFile(path);
    _cachedActiveText = null;
    notifyListeners();
    return true;
  }

  /// Save the active tab
  Future<bool> saveActiveTab() async {
    final tab = activeTab;
    if (tab == null) return false;

    if (tab.filePath == null) {
      return false; // Need "Save As" - caller should handle
    }

    final content = tab.getSaveContent();

    if (tab.isEncrypted && tab.password != null) {
      await _fileService.writeScrbFile(tab.filePath!, content, tab.password!);
    } else {
      await _fileService.writeTxtFile(tab.filePath!, content);
    }
    tab.markSaved();
    notifyListeners();
    return true;
  }

  /// Save the active tab to a specific path
  Future<bool> saveActiveTabAs(String path, {bool encrypted = false, String? password}) async {
    final tab = activeTab;
    if (tab == null) return false;

    final content = tab.getSaveContent();

    if (encrypted && password != null) {
      await _fileService.writeScrbFile(path, content, password);
      tab.isEncrypted = true;
      tab.password = password;
    } else {
      final ext = _fileService.getExtension(path);
      if (ext == '.rtf' && tab.mode == EditorMode.richText) {
        // RTF save handled by caller (main_screen) via RtfService
        await _fileService.writeTxtFile(path, content);
      } else {
        await _fileService.writeTxtFile(path, content);
      }
      tab.isEncrypted = false;
      tab.password = null;
    }

    tab.filePath = path;
    tab.fileName = _fileService.getFileName(path);
    tab.markSaved();
    await _settingsService.addRecentFile(path);
    notifyListeners();
    return true;
  }

  /// Mark active tab as saved to a new path (used for RTF save)
  void markTabSavedAs(String path) {
    final tab = activeTab;
    if (tab == null) return;
    tab.filePath = path;
    tab.fileName = _fileService.getFileName(path);
    tab.isEncrypted = false;
    tab.password = null;
    tab.markSaved();
    _settingsService.addRecentFile(path);
    notifyListeners();
  }

  /// Toggle encryption on active tab
  void toggleEncryption() {
    final tab = activeTab;
    if (tab == null) return;
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
    tab.tabFontSize = size.clamp(8.0, 48.0);
    notifyListeners();
  }

  /// Toggle between plain text and rich text mode
  void toggleEditorMode() {
    final tab = activeTab;
    if (tab == null) return;

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

    _cachedActiveText = null;
    notifyListeners();
  }

  /// Update the delta JSON for the active tab (called by QuillEditor widget)
  void updateDeltaJson(String json) {
    final tab = activeTab;
    if (tab == null) return;
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

  // Search
  void toggleSearch() {
    _showSearch = !_showSearch;
    notifyListeners();
  }

  void showSearchBar() {
    _showSearch = true;
    notifyListeners();
  }

  /// Called when editor content changes - debounced to avoid excessive rebuilds.
  /// Invalidates the cached plain-text so word/char/line counts recompute once
  /// per notification cycle (not once per getter call).
  void onContentChanged() {
    _contentDebounce?.cancel();
    _contentDebounce = Timer(_debounceDuration, () {
      _cachedActiveText = null;
      notifyListeners();
    });
  }

  // Word/character count for active tab.
  // _activeText is cached per notification cycle — computed at most once per
  // 300 ms debounce, even though wordCount/charCount/lineCount each call it.
  String get _activeText {
    if (_cachedActiveText != null) return _cachedActiveText!;
    final tab = activeTab;
    if (tab == null) return _cachedActiveText = '';
    if (tab.mode == EditorMode.richText) {
      return _cachedActiveText = _extractPlainTextFromDelta(tab.deltaJson);
    }
    return _cachedActiveText = tab.controller.text;
  }

  int get wordCount {
    final text = _activeText;
    if (text.trim().isEmpty) return 0;
    return RegExp(r'\S+').allMatches(text).length;
  }

  int get charCount => _activeText.length;

  int get lineCount {
    final text = _activeText;
    if (text.isEmpty) return 1;
    return '\n'.allMatches(text).length + 1;
  }

  /// Plain text content of the active tab for searching.
  /// Works in both plain text and rich text mode.
  String get searchableText => _activeText;

  @override
  void dispose() {
    _settingsService.removeListener(_onSettingsChanged);
    _autoSaveTimer?.cancel();
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
