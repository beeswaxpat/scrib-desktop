import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:scrib_desktop/providers/editor_provider.dart';
import 'package:scrib_desktop/services/file_service.dart';
import 'package:scrib_desktop/services/settings_service.dart';

/// Batch tab-close (closeTabs) behavior used by the right-click tab menu
/// (Close Others / Close to the Right / Close All).
void main() {
  late Directory tmp;
  late SettingsService settings;
  late EditorProvider editor;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('scrib_closetabs_');
    settings = SettingsService();
    await settings.initForTests(tmp.path);
    editor = EditorProvider(FileService(), settings);
  });

  tearDown(() async {
    editor.dispose();
    await Hive.close();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  group('closeTabs', () {
    test('closes clean tabs in one pass and keeps the active tab when it survives', () {
      editor.addNewTab();
      editor.addNewTab();
      editor.addNewTab();
      editor.setActiveTab(1);
      final keep = editor.tabs[1];

      final dirty = editor.closeTabs(
        [editor.tabs[0], editor.tabs[2], editor.tabs[3]],
      );

      expect(dirty, isEmpty);
      expect(editor.tabs.length, 1);
      expect(editor.tabs.first, same(keep));
      expect(editor.activeTab, same(keep));
    });

    test('leaves dirty tabs open and returns them for prompting', () {
      editor.addNewTab();
      editor.addNewTab();
      editor.tabs[1].controller.text = 'unsaved work'; // make tab 1 dirty

      final dirty = editor.closeTabs(editor.tabs.toList());

      expect(dirty.length, 1);
      expect(dirty.first.controller.text, 'unsaved work');
      expect(editor.tabs.length, 1); // only the dirty tab survives
      expect(editor.tabs.first, same(dirty.first));
    });

    test('closing every clean tab leaves a single fresh blank tab', () {
      editor.addNewTab();
      editor.addNewTab();

      final dirty = editor.closeTabs(editor.tabs.toList());

      expect(dirty, isEmpty);
      expect(editor.tabs.length, 1);
      expect(editor.tabs.first.filePath, isNull);
      expect(editor.activeTabIndex, 0);
    });

    test('empty input is a no-op', () {
      editor.addNewTab();
      final before = editor.tabs.length;
      expect(editor.closeTabs(const []), isEmpty);
      expect(editor.tabs.length, before);
    });

    test('active index is clamped when the active tab is closed', () {
      editor.addNewTab();
      editor.addNewTab();
      editor.setActiveTab(2);
      final active = editor.tabs[2];

      editor.closeTabs([active, editor.tabs[0]]);

      expect(editor.tabs.contains(active), isFalse);
      expect(editor.tabs.length, 1);
      expect(editor.activeTabIndex, 0);
    });
  });
}
