import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:scrib_desktop/services/settings_service.dart';

/// Covers SettingsService defaults, every setter's round-trip + notify
/// behavior, and the recent-files MRU semantics.
void main() {
  late Directory tmp;
  late SettingsService settings;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('scrib_settings_');
    settings = SettingsService();
    await settings.initForTests(tmp.path);
  });

  tearDown(() async {
    await Hive.close();
    try { await tmp.delete(recursive: true); } catch (_) {}
  });

  group('defaults', () {
    test('themeMode defaults to dark (2)', () {
      expect(settings.themeMode, 2);
    });
    test('font defaults are JetBrains Mono / 14.0', () {
      expect(settings.fontFamily, 'JetBrains Mono');
      expect(settings.fontSize, 14.0);
    });
    test('wordWrap defaults true and showLineNumbers defaults false', () {
      expect(settings.wordWrap, isTrue);
      expect(settings.showLineNumbers, isFalse);
    });
    test('autoSaveInterval defaults to 30 seconds', () {
      expect(settings.autoSaveInterval, 30);
    });
    test('accentColorIndex defaults to 0', () {
      expect(settings.accentColorIndex, 0);
    });
    test('window defaults are 900x650, null position, not maximized', () {
      expect(settings.windowWidth, 900.0);
      expect(settings.windowHeight, 650.0);
      expect(settings.windowX, isNull);
      expect(settings.windowY, isNull);
      expect(settings.windowMaximized, isFalse);
    });
    test('recentFiles defaults to an empty list (not null)', () {
      expect(settings.recentFiles, isEmpty);
      expect(settings.defaultSaveLocation, '');
    });
  });

  group('setters round-trip and notify', () {
    test('setThemeMode persists and notifies once', () async {
      int n = 0;
      settings.addListener(() => n++);
      await settings.setThemeMode(1);
      expect(settings.themeMode, 1);
      expect(n, 1);
    });
    test('setAccentColorIndex persists and notifies', () async {
      int n = 0;
      settings.addListener(() => n++);
      await settings.setAccentColorIndex(3);
      expect(settings.accentColorIndex, 3);
      expect(n, 1);
    });
    test('font, wrap and line-number setters each persist and notify', () async {
      int n = 0;
      settings.addListener(() => n++);
      await settings.setFontFamily('Consolas');
      await settings.setFontSize(18.0);
      await settings.setWordWrap(false);
      await settings.setShowLineNumbers(true);
      await settings.setAutoSaveInterval(0);
      expect(settings.fontFamily, 'Consolas');
      expect(settings.fontSize, 18.0);
      expect(settings.wordWrap, isFalse);
      expect(settings.showLineNumbers, isTrue);
      expect(settings.autoSaveInterval, 0);
      expect(n, 5);
    });
    test('setDefaultSaveLocation persists and notifies', () async {
      int n = 0;
      settings.addListener(() => n++);
      await settings.setDefaultSaveLocation(r'C:\Notes');
      expect(settings.defaultSaveLocation, r'C:\Notes');
      expect(n, 1);
    });
    test('saveWindowState persists all fields WITHOUT notifying', () async {
      int n = 0;
      settings.addListener(() => n++);
      await settings.saveWindowState(
          width: 1024, height: 768, x: 12, y: 34, maximized: true);
      expect(settings.windowWidth, 1024);
      expect(settings.windowHeight, 768);
      expect(settings.windowX, 12);
      expect(settings.windowY, 34);
      expect(settings.windowMaximized, isTrue);
      expect(n, 0, reason: 'window state is internal — must not notify the UI');
    });
  });

  group('recent files MRU', () {
    test('addRecentFile inserts at the front', () async {
      await settings.addRecentFile('/a.txt');
      await settings.addRecentFile('/b.txt');
      expect(settings.recentFiles.first, '/b.txt');
    });
    test('re-adding an existing path moves it to the front (dedupe)', () async {
      await settings.addRecentFile('/a.txt');
      await settings.addRecentFile('/b.txt');
      await settings.addRecentFile('/a.txt');
      expect(settings.recentFiles.first, '/a.txt');
      expect(settings.recentFiles.where((p) => p == '/a.txt').length, 1);
    });
    test('the list is capped at 10 entries', () async {
      for (int i = 0; i < 15; i++) {
        await settings.addRecentFile('/file$i.txt');
      }
      expect(settings.recentFiles.length, 10);
      expect(settings.recentFiles.first, '/file14.txt');
    });
    test('clearRecentFiles empties the list and notifies', () async {
      await settings.addRecentFile('/a.txt');
      int n = 0;
      settings.addListener(() => n++);
      await settings.clearRecentFiles();
      expect(settings.recentFiles, isEmpty);
      expect(n, 1);
    });
  });
}
