import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:scrib_desktop/providers/editor_provider.dart';
import 'package:scrib_desktop/services/file_service.dart';
import 'package:scrib_desktop/services/settings_service.dart';

/// Session restore: the quit-time snapshot records paths only, and restore
/// reopens plain files while encrypted files come back LOCKED (no password,
/// no content in memory).
void main() {
  late Directory tmp;
  late SettingsService settings;
  late EditorProvider editor;
  late FileService fs;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('scrib_session_');
    settings = SettingsService();
    await settings.initForTests(tmp.path);
    fs = FileService();
    editor = EditorProvider(fs, settings);
  });

  tearDown(() async {
    editor.dispose();
    await Hive.close();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  String p(String name) => '${tmp.path}${Platform.pathSeparator}$name';

  group('sessionSnapshot', () {
    test('records only file-backed tabs, with colors', () async {
      final a = p('a.txt');
      await File(a).writeAsString('hello');
      await editor.openFile(a);
      editor.setTabColor(2);
      editor.addNewTab(); // untitled — must not be recorded

      final snap = editor.sessionSnapshot();
      expect(snap.length, 1);
      expect(snap[0]['path'], a);
      expect(snap[0]['color'], 2);
      expect(snap[0].containsKey('content'), isFalse);
    });

    test('sessionActiveIndex maps the active tab into snapshot space', () async {
      final a = p('a.txt');
      final b = p('b.txt');
      await File(a).writeAsString('a');
      await File(b).writeAsString('b');
      editor.addNewTab(); // untitled stays at index 0
      await editor.openFile(a);
      await editor.openFile(b);

      // Active tab is b — third overall, but second file-backed entry.
      expect(editor.sessionActiveIndex, 1);
    });
  });

  group('settings persistence', () {
    test('saveSession round-trips tabs and active index', () async {
      await settings.saveSession([
        {'path': 'C:\\x.txt'},
        {'path': 'C:\\y.scrb', 'color': 3},
      ], 1);

      final tabs = settings.sessionTabs;
      expect(tabs.length, 2);
      expect(tabs[0]['path'], 'C:\\x.txt');
      expect(tabs[1]['color'], 3);
      expect(settings.sessionActiveIndex, 1);
    });

    test('turning restore off clears the stored session', () async {
      await settings.saveSession([
        {'path': 'C:\\x.txt'}
      ], 0);
      expect(settings.sessionTabs, isNotEmpty);

      await settings.setRestoreSession(false);
      expect(settings.restoreSession, isFalse);
      expect(settings.sessionTabs, isEmpty);
    });

    test('corrupt session JSON is treated as empty', () async {
      final box = await Hive.openBox('scrib_desktop_settings');
      await box.put('sessionJson', '{not valid json');
      expect(settings.sessionTabs, isEmpty);
      expect(settings.sessionActiveIndex, 0);
    });

    test('restoreSession defaults to on', () {
      expect(settings.restoreSession, isTrue);
    });
  });

  group('restorePreviousSession', () {
    test('reopens plain files and restores encrypted files LOCKED', () async {
      final a = p('notes.txt');
      await File(a).writeAsString('plain notes');
      final b = p('secrets.scrb');
      await fs.writeScrbFile(b, 'classified', 'pw', iterations: 1000);

      await settings.saveSession([
        {'path': a},
        {'path': b, 'color': 2},
      ], 1);

      // Fresh provider = fresh launch.
      final launched = EditorProvider(fs, settings);
      addTearDown(launched.dispose);

      final restored = await launched.restorePreviousSession();
      expect(restored, 2);
      expect(launched.tabs.length, 2);

      final txtTab = launched.tabs[0];
      expect(txtTab.filePath, a);
      expect(txtTab.controller.text, 'plain notes');
      expect(txtTab.isLocked, isFalse);

      final scrbTab = launched.tabs[1];
      expect(scrbTab.filePath, b);
      expect(scrbTab.isLocked, isTrue);
      expect(scrbTab.isEncrypted, isTrue);
      expect(scrbTab.password, isNull);
      expect(scrbTab.controller.text, isEmpty);
      expect(scrbTab.colorIndex, 2);

      // Saved active index 1 → the encrypted tab is active.
      expect(launched.activeTab, same(scrbTab));

      // The locked restore never modified the file: it still decrypts.
      expect(await fs.readScrbFile(b, 'pw'), 'classified');
    });

    test('skips files that no longer exist', () async {
      final a = p('still-here.txt');
      await File(a).writeAsString('kept');

      await settings.saveSession([
        {'path': p('gone.txt')},
        {'path': a},
      ], 0);

      final launched = EditorProvider(fs, settings);
      addTearDown(launched.dispose);

      final restored = await launched.restorePreviousSession();
      expect(restored, 1);
      expect(launched.tabs.length, 1);
      expect(launched.tabs[0].filePath, a);
    });

    test('empty session restores nothing and keeps the untitled tab', () async {
      final launched = EditorProvider(fs, settings);
      addTearDown(launched.dispose);
      expect(await launched.restorePreviousSession(), 0);
      expect(launched.tabs.length, 1);
      expect(launched.tabs[0].filePath, isNull);
    });
  });

  group('auto-lock setting', () {
    test('autoLockMinutes defaults to off and persists', () async {
      expect(settings.autoLockMinutes, 0);
      await settings.setAutoLockMinutes(5);
      expect(settings.autoLockMinutes, 5);
    });
  });
}
