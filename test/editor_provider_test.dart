import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:scrib_desktop/providers/editor_provider.dart';
import 'package:scrib_desktop/services/file_service.dart';
import 'package:scrib_desktop/services/settings_service.dart';

/// Tab-management tests. These don't need Flutter widgets — they exercise
/// the provider's plain-Dart state machine directly.
void main() {
  late Directory tmp;
  late SettingsService settings;
  late EditorProvider editor;
  late FileService fs;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('scrib_provider_');
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

  group('tab lifecycle', () {
    test('starts with one blank tab', () {
      expect(editor.tabs.length, 1);
      expect(editor.activeTabIndex, 0);
      expect(editor.activeTab?.filePath, isNull);
    });

    test('addNewTab appends a tab and activates it', () {
      editor.addNewTab();
      expect(editor.tabs.length, 2);
      expect(editor.activeTabIndex, 1);
    });

    test('closeTab on the only clean blank tab keeps a placeholder', () {
      editor.closeTab(0);
      expect(editor.tabs.length, 1); // always has at least one tab
      expect(editor.activeTabIndex, 0);
    });

    test('closeTab shifts activeTabIndex when closing to the left', () {
      editor.addNewTab();
      editor.addNewTab();
      editor.setActiveTab(2);
      editor.closeTab(0);
      expect(editor.tabs.length, 2);
      expect(editor.activeTabIndex, 1); // shifted down
    });

    test('renameTab changes displayed name', () {
      editor.renameTab(0, 'my_note');
      expect(editor.tabs[0].fileName, 'my_note');
    });
  });

  group('mode toggle + revert', () {
    test('plain → rich + revert restores plain text', () {
      final tab = editor.activeTab!;
      tab.controller.text = 'hello';
      expect(tab.mode, EditorMode.plainText);

      editor.toggleEditorMode();
      expect(tab.mode, EditorMode.richText);
      expect(tab.deltaJson, isNotEmpty);

      final reverted = editor.revertModeToggle();
      expect(reverted, isTrue);
      expect(tab.mode, EditorMode.plainText);
      expect(tab.controller.text, 'hello');
    });

    test('rich → plain + revert restores formatted Delta', () {
      final tab = editor.activeTab!;
      tab.mode = EditorMode.richText;
      final original = jsonEncode([
        {'insert': 'bold', 'attributes': {'bold': true}},
        {'insert': '\n'}
      ]);
      tab.deltaJson = original;

      editor.toggleEditorMode();
      expect(tab.mode, EditorMode.plainText);

      final reverted = editor.revertModeToggle();
      expect(reverted, isTrue);
      expect(tab.mode, EditorMode.richText);
      expect(tab.deltaJson, original);
    });

    test('revertModeToggle returns false when no snapshot exists', () {
      expect(editor.revertModeToggle(), isFalse);
    });

    test('markSaved clears the snapshot', () {
      final tab = editor.activeTab!;
      tab.controller.text = 'x';
      editor.toggleEditorMode();
      expect(tab.preToggleSnapshot, isNotNull);
      tab.markSaved();
      expect(tab.preToggleSnapshot, isNull);
    });
  });

  // Global search behavior (sorting, case-insensitivity, empty query, table
  // cell text) is tested at the widget level in global_search_widget_test.dart:
  // the search-all-tabs logic lives in GlobalSearchPanel since the provider's
  // orphaned searchAllTabs helper was removed.

  group('stats', () {
    test('word count ignores multiple spaces', () {
      editor.activeTab!.controller.text = 'one  two\tthree\nfour';
      editor.invalidateTextCache();
      expect(editor.wordCount, 4);
    });

    test('line count on empty text is 1', () {
      editor.activeTab!.controller.text = '';
      editor.invalidateTextCache();
      expect(editor.lineCount, 1);
    });

    test('line count counts newlines + 1', () {
      editor.activeTab!.controller.text = 'a\nb\nc';
      editor.invalidateTextCache();
      expect(editor.lineCount, 3);
    });
  });

  group('settings persistence smoke test', () {
    test('setThemeMode round-trips through Hive', () async {
      await settings.setThemeMode(1);
      expect(settings.themeMode, 1);
      await settings.setThemeMode(2);
      expect(settings.themeMode, 2);
    });

    test('recentFiles MRU caps at 10 and deduplicates', () async {
      for (int i = 0; i < 15; i++) {
        await settings.addRecentFile('/path/file$i.txt');
      }
      expect(settings.recentFiles.length, 10);
      expect(settings.recentFiles.first, '/path/file14.txt');

      // Adding an existing path moves it to the front.
      await settings.addRecentFile('/path/file10.txt');
      expect(settings.recentFiles.first, '/path/file10.txt');
      expect(settings.recentFiles.length, 10);
    });
  });
}
