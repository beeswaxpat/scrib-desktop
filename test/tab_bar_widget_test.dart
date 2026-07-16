import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:provider/provider.dart';
import 'package:scrib_desktop/providers/editor_provider.dart';
import 'package:scrib_desktop/services/file_service.dart';
import 'package:scrib_desktop/services/settings_service.dart';
import 'package:scrib_desktop/widgets/tab_bar_widget.dart';

/// Tab strip behavior: Escape cancels an inline rename (Enter still commits),
/// and activating a tab that is scrolled out of view brings it into view.
void main() {
  late Directory tmp;
  late SettingsService settings;
  late EditorProvider editor;
  late FileService fs;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('scrib_tabbar_');
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

  Widget harness({
    required List<(int, String)> renameCalls,
    double width = 900,
  }) =>
      MaterialApp(
        home: ChangeNotifierProvider<EditorProvider>.value(
          value: editor,
          child: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                child: ScribTabBar(
                  onCloseTab: (i) => editor.closeTab(i),
                  onRenameTab: (i, name) => renameCalls.add((i, name)),
                  onCloseOthers: (_) {},
                  onCloseToRight: (_) {},
                  onCloseAll: () {},
                ),
              ),
            ),
          ),
        ),
      );

  Future<void> startRename(WidgetTester t, String tabName) async {
    await t.tap(find.text(tabName));
    await t.pump(const Duration(milliseconds: 80));
    await t.tap(find.text(tabName));
    await t.pumpAndSettle();
  }

  testWidgets('Escape cancels an in-progress rename without committing',
      (t) async {
    final renameCalls = <(int, String)>[];
    final tabName = editor.tabs.first.fileName;

    await t.pumpWidget(harness(renameCalls: renameCalls));
    await startRename(t, tabName);
    expect(find.byType(TextField), findsOneWidget);

    await t.enterText(find.byType(TextField), 'AccidentalName');
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();

    expect(find.byType(TextField), findsNothing,
        reason: 'Escape must close the rename editor');
    expect(renameCalls, isEmpty,
        reason: 'a cancelled rename must not commit');
    expect(find.text(tabName), findsOneWidget);
  });

  testWidgets('Enter still commits a rename', (t) async {
    final renameCalls = <(int, String)>[];
    final tabName = editor.tabs.first.fileName;

    await t.pumpWidget(harness(renameCalls: renameCalls));
    await startRename(t, tabName);

    await t.enterText(find.byType(TextField), 'RenamedTab');
    await t.testTextInput.receiveAction(TextInputAction.done);
    await t.pumpAndSettle();

    expect(renameCalls, [(0, 'RenamedTab')]);
  });

  testWidgets('activating a tab scrolled out of view reveals it', (t) async {
    // 12 tabs at minWidth 100 in a 500px strip: most are out of view.
    for (int i = 0; i < 11; i++) {
      editor.addNewTab();
    }
    editor.setActiveTab(0); // start pinned to the left edge
    final renameCalls = <(int, String)>[];
    await t.pumpWidget(harness(renameCalls: renameCalls, width: 500));
    await t.pumpAndSettle();

    final lastName = editor.tabs.last.displayName;
    // Off the right edge initially.
    expect(t.getRect(find.text(lastName)).left, greaterThan(500));

    editor.setActiveTab(editor.tabs.length - 1);
    await t.pumpAndSettle();

    final rect = t.getRect(find.text(lastName));
    expect(rect.right, lessThanOrEqualTo(500),
        reason: 'the activated tab must be scrolled into view');
    expect(rect.left, greaterThanOrEqualTo(0));
  });
}
