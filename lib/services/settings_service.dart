import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:path_provider/path_provider.dart';

/// Desktop settings persistence using Hive.
/// Extends ChangeNotifier so the widget tree reacts to settings changes.
class SettingsService extends ChangeNotifier {
  static const String _settingsBoxName = 'scrib_desktop_settings';

  late Box<dynamic> _settingsBox;

  Future<void> init() async {
    final appDir = await getApplicationSupportDirectory();
    Hive.init(appDir.path);
    _settingsBox = await Hive.openBox(_settingsBoxName);
  }

  /// Test-only initializer that opens the settings box in [directory] without
  /// relying on path_provider (which is unavailable in headless tests).
  @visibleForTesting
  Future<void> initForTests(String directory) async {
    Hive.init(directory);
    _settingsBox = await Hive.openBox(_settingsBoxName);
  }

  // Theme mode: 0 = system, 1 = light, 2 = dark
  int get themeMode => _settingsBox.get('themeMode', defaultValue: 2);

  Future<void> setThemeMode(int value) async {
    await _settingsBox.put('themeMode', value);
    notifyListeners();
  }

  // Accent color (0-4)
  int get accentColorIndex => _settingsBox.get('accentColorIndex', defaultValue: 0);

  Future<void> setAccentColorIndex(int value) async {
    await _settingsBox.put('accentColorIndex', value);
    notifyListeners();
  }

  // Font family
  String get fontFamily => _settingsBox.get('fontFamily', defaultValue: 'JetBrains Mono');

  Future<void> setFontFamily(String value) async {
    await _settingsBox.put('fontFamily', value);
    notifyListeners();
  }

  // Font size
  double get fontSize => _settingsBox.get('fontSize', defaultValue: 14.0);

  Future<void> setFontSize(double value) async {
    await _settingsBox.put('fontSize', value);
    notifyListeners();
  }

  // Word wrap
  bool get wordWrap => _settingsBox.get('wordWrap', defaultValue: true);

  Future<void> setWordWrap(bool value) async {
    await _settingsBox.put('wordWrap', value);
    notifyListeners();
  }

  // Line numbers
  bool get showLineNumbers => _settingsBox.get('showLineNumbers', defaultValue: false);

  Future<void> setShowLineNumbers(bool value) async {
    await _settingsBox.put('showLineNumbers', value);
    notifyListeners();
  }

  // Auto-save interval in seconds (0 = disabled)
  int get autoSaveInterval => _settingsBox.get('autoSaveInterval', defaultValue: 30);

  Future<void> setAutoSaveInterval(int value) async {
    await _settingsBox.put('autoSaveInterval', value);
    notifyListeners();
  }

  // Window size persistence (no notifyListeners - internal only)
  double get windowWidth => _settingsBox.get('windowWidth', defaultValue: 900.0);
  double get windowHeight => _settingsBox.get('windowHeight', defaultValue: 650.0);
  double? get windowX => _settingsBox.get('windowX');
  double? get windowY => _settingsBox.get('windowY');
  bool get windowMaximized => _settingsBox.get('windowMaximized', defaultValue: false);

  Future<void> saveWindowState({
    required double width,
    required double height,
    required double x,
    required double y,
    required bool maximized,
  }) async {
    await _settingsBox.putAll({
      'windowWidth': width,
      'windowHeight': height,
      'windowX': x,
      'windowY': y,
      'windowMaximized': maximized,
    });
  }

  // Recent files
  List<String> get recentFiles {
    final raw = _settingsBox.get('recentFiles', defaultValue: <dynamic>[]);
    return List<String>.from(raw);
  }

  Future<void> addRecentFile(String path) async {
    final files = recentFiles;
    files.remove(path);
    files.insert(0, path);
    if (files.length > 10) files.removeLast();
    await _settingsBox.put('recentFiles', files);
  }

  /// Clear the recent-files list AND rewrite the box on disk.
  ///
  /// Hive is an append-only log: `put` writes a new frame and leaves the old
  /// one in the file, so without the compaction the note paths the user just
  /// asked to forget are still sitting in `%APPDATA%` in plain text. Compaction
  /// rewrites the file from live values only.
  Future<void> clearRecentFiles() async {
    await _settingsBox.put('recentFiles', <String>[]);
    await _compactQuietly();
    notifyListeners();
  }

  /// Compaction is housekeeping: a failure must never take down the caller.
  Future<void> _compactQuietly() async {
    try {
      await _settingsBox.compact();
    } catch (e) {
      if (kDebugMode) debugPrint('Hive compaction skipped: $e');
    }
  }

  // Default save location
  String get defaultSaveLocation => _settingsBox.get('defaultSaveLocation', defaultValue: '');

  Future<void> setDefaultSaveLocation(String value) async {
    await _settingsBox.put('defaultSaveLocation', value);
    notifyListeners();
  }

  // Auto-lock idle threshold in minutes (0 = disabled). When enabled, every
  // encrypted tab locks after this much user inactivity.
  int get autoLockMinutes => _settingsBox.get('autoLockMinutes', defaultValue: 0);

  Future<void> setAutoLockMinutes(int value) async {
    await _settingsBox.put('autoLockMinutes', value);
    notifyListeners();
  }

  // ── Session restore ────────────────────────────────────────────────────
  // The stored session is a JSON object {tabs: [{path, color?}], active: int}
  // written on quit. It records file PATHS only — never content or passwords.

  bool get restoreSession => _settingsBox.get('restoreSession', defaultValue: true);

  /// Turning restore off also clears any stored session, so disabling it
  /// removes the record of what was open.
  Future<void> setRestoreSession(bool value) async {
    await _settingsBox.put('restoreSession', value);
    if (!value) await clearSession();
    notifyListeners();
  }

  Future<void> saveSession(List<Map<String, dynamic>> tabs, int activeIndex) async {
    await _settingsBox.put(
      'sessionJson',
      jsonEncode({'tabs': tabs, 'active': activeIndex}),
    );
  }

  /// Delete the stored session and rewrite the box, so the paths of the notes
  /// that were open are not left behind in Hive's append-only log. Turning
  /// session restore off is a privacy action, not just a preference.
  Future<void> clearSession() async {
    await _settingsBox.delete('sessionJson');
    await _compactQuietly();
  }

  List<Map<String, dynamic>> get sessionTabs {
    final raw = _settingsBox.get('sessionJson');
    if (raw is! String || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      final tabs = decoded is Map ? decoded['tabs'] : null;
      if (tabs is! List) return const [];
      return [
        for (final t in tabs)
          if (t is Map) Map<String, dynamic>.from(t),
      ];
    } catch (_) {
      return const [];
    }
  }

  int get sessionActiveIndex {
    final raw = _settingsBox.get('sessionJson');
    if (raw is! String || raw.isEmpty) return 0;
    try {
      final decoded = jsonDecode(raw);
      final active = decoded is Map ? decoded['active'] : null;
      return active is int && active >= 0 ? active : 0;
    } catch (_) {
      return 0;
    }
  }
}
