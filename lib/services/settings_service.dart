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

  Future<void> clearRecentFiles() async {
    await _settingsBox.put('recentFiles', <String>[]);
    notifyListeners();
  }

  // Default save location
  String get defaultSaveLocation => _settingsBox.get('defaultSaveLocation', defaultValue: '');

  Future<void> setDefaultSaveLocation(String value) async {
    await _settingsBox.put('defaultSaveLocation', value);
    notifyListeners();
  }
}
