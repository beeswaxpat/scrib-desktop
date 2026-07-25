import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:provider/provider.dart';
import 'package:scrib_desktop/providers/editor_provider.dart';
import 'package:scrib_desktop/services/file_service.dart';
import 'package:scrib_desktop/services/settings_service.dart';
import 'package:scrib_desktop/services/table_embed.dart';
import 'package:scrib_desktop/widgets/global_search_widget.dart';

/// Global search panel: typing is debounced, results resolve tabs by identity
/// (immune to tab closes while the panel is open), and the whole flow works
/// from the keyboard (Enter opens, arrows move the selection).
void main() {
  late Directory tmp;
  late SettingsService settings;
  late EditorProvider editor;
  late FileService fs;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('scrib_gsearch_');
    settings = SettingsService();
    await settings.initForTests(tmp.path);
    fs = FileService();
    editor = EditorProvider(fs, settings);
    GlobalSearchPanel.debugCachedExtractionCount = 0;
  });

  tearDown(() async {
    editor.dispose();
    await Hive.close();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Widget harness() => MaterialApp(
        home: ChangeNotifierProvider<EditorProvider>.value(
          value: editor,
          child: const Scaffold(body: GlobalSearchPanel()),
        ),
      );

  Future<void> typeQuery(WidgetTester t, String query) async {
    await t.enterText(find.byType(TextField), query);
    await t.pump(const Duration(milliseconds: 300)); // > 250ms debounce
  }

  testWidgets('typing is debounced before searching', (t) async {
    editor.tabs[0].controller.text = 'apple pie';
    await t.pumpWidget(harness());

    await t.enterText(find.byType(TextField), 'apple');
    await t.pump(const Duration(milliseconds: 100));
    expect(find.byIcon(Icons.description_outlined), findsNothing,
        reason: 'no results before the debounce fires');

    await t.pump(const Duration(milliseconds: 200));
    expect(find.byIcon(Icons.description_outlined), findsOneWidget);
  });

  testWidgets('Enter opens the top result and pre-fills the find bar',
      (t) async {
    editor.tabs[0].controller.text = 'nothing here';
    editor.addNewTab();
    final target = editor.activeTab!;
    target.controller.text = 'apple apple apple';
    editor.setActiveTab(0);

    await t.pumpWidget(harness());
    await typeQuery(t, 'apple');
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pump();

    expect(editor.activeTab, same(target));
    expect(editor.showSearch, isTrue);
    expect(editor.pendingFindQuery, 'apple');
  });

  testWidgets('arrow keys move the selection and Enter opens it', (t) async {
    // Two matching tabs; results are sorted by match count desc.
    final first = editor.tabs[0];
    first.controller.text = 'banana banana';
    editor.addNewTab();
    final second = editor.activeTab!;
    second.controller.text = 'banana';
    editor.setActiveTab(0);

    await t.pumpWidget(harness());
    await typeQuery(t, 'banana');
    expect(find.byIcon(Icons.description_outlined), findsNWidgets(2));

    await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pump();

    expect(editor.activeTab, same(second),
        reason: 'ArrowDown must select the second-ranked result');
  });

  testWidgets('closing a tab while the panel is open cannot misroute a click',
      (t) async {
    final first = editor.tabs[0];
    first.controller.text = 'target target target'; // rank 1
    editor.addNewTab();
    final second = editor.activeTab!;
    second.controller.text = 'target'; // rank 2
    editor.setActiveTab(0);

    await t.pumpWidget(harness());
    await typeQuery(t, 'target');
    expect(find.byIcon(Icons.description_outlined), findsNWidgets(2));

    // Close the top-ranked tab out from under the results.
    editor.closeTab(0);
    await t.pump();

    // The panel re-queries on provider change: one row left.
    expect(find.byIcon(Icons.description_outlined), findsOneWidget);

    await t.tap(find.byIcon(Icons.description_outlined));
    await t.pump();
    expect(editor.activeTab, same(second),
        reason: 'the click must land on the surviving tab, not a stale index');
  });

  testWidgets('results are sorted by match count descending', (t) async {
    editor.tabs[0].controller.text = 'apple pie';
    editor.addNewTab();
    editor.activeTab!.controller.text = 'apple apple apple';
    editor.addNewTab();
    editor.activeTab!.controller.text = 'orange';
    editor.setActiveTab(0);

    await t.pumpWidget(harness());
    await typeQuery(t, 'apple');

    expect(find.byIcon(Icons.description_outlined), findsNWidgets(2),
        reason: 'the tab without a match must not appear');
    final threePill = t.getTopLeft(find.text('3'));
    final onePill = t.getTopLeft(find.text('1'));
    expect(threePill.dy, lessThan(onePill.dy),
        reason: 'the tab with 3 matches must rank above the tab with 1');
  });

  testWidgets('blank query shows no results', (t) async {
    editor.tabs[0].controller.text = 'apple pie';
    await t.pumpWidget(harness());

    await typeQuery(t, '   ');
    expect(find.byIcon(Icons.description_outlined), findsNothing);
  });

  testWidgets('match counting is case-insensitive', (t) async {
    editor.tabs[0].controller.text = 'Hello HELLO hello';
    await t.pumpWidget(harness());

    await typeQuery(t, 'hello');
    expect(find.byIcon(Icons.description_outlined), findsOneWidget);
    expect(find.text('3'), findsOneWidget,
        reason: 'all three case variants must count');
  });

  testWidgets('finds matches inside table cells of rich tabs', (t) async {
    final tab = editor.tabs[0];
    tab.mode = EditorMode.richText;
    final table =
        ScribTable.empty(rows: 1, cols: 1, id: 't').withCell(0, 0, 'needle');
    tab.deltaJson = jsonEncode([
      {'insert': 'hay\n'},
      {'insert': table.toEmbed().toJson()},
      {'insert': '\n'},
    ]);

    await t.pumpWidget(harness());
    await typeQuery(t, 'needle');

    expect(find.byIcon(Icons.description_outlined), findsOneWidget,
        reason: 'text living only in a table cell must be searchable');
    expect(find.text('1'), findsOneWidget);
  });

  group('locked tabs and cached plaintext', () {
    // A rich tab, because only rich tabs go through the extraction cache: the
    // cache holds the full decrypted note, so it has to die with the search.
    void seedRichTab() {
      final tab = editor.tabs[0];
      tab.mode = EditorMode.richText;
      tab.deltaJson = jsonEncode([
        {'insert': 'secret needle\n'}
      ]);
    }

    testWidgets('a locked tab is neither searched nor left cached', (t) async {
      seedRichTab();
      await t.pumpWidget(harness());
      await typeQuery(t, 'needle');
      expect(find.byIcon(Icons.description_outlined), findsOneWidget);
      expect(GlobalSearchPanel.debugCachedExtractionCount, 1);

      // Lock WITHOUT wiping the content: the panel must refuse the tab on
      // isLocked alone rather than relying on EditorTab.lock() having emptied
      // it, and it must not answer from the text it cached before the lock.
      editor.tabs[0].isLocked = true;
      editor.setActiveTab(0); // notify: the panel re-queries on provider change
      await t.pump();

      expect(find.byIcon(Icons.description_outlined), findsNothing);
      expect(find.text('No matches in any open tab'), findsOneWidget);
      expect(GlobalSearchPanel.debugCachedExtractionCount, 0);
    });

    testWidgets('clearing the query drops the cached decrypted text',
        (t) async {
      seedRichTab();
      await t.pumpWidget(harness());
      await typeQuery(t, 'needle');
      expect(GlobalSearchPanel.debugCachedExtractionCount, 1);

      await typeQuery(t, '');
      expect(GlobalSearchPanel.debugCachedExtractionCount, 0,
          reason: 'the empty-query early return used to skip the prune, so '
              'every rich tab stayed resident in plaintext while the panel '
              'sat open on a cleared field');
    });

    testWidgets('closing the panel drops the cached decrypted text', (t) async {
      seedRichTab();
      await t.pumpWidget(harness());
      await typeQuery(t, 'needle');
      expect(GlobalSearchPanel.debugCachedExtractionCount, 1);

      await t.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<EditorProvider>.value(
            value: editor,
            child: const Scaffold(body: SizedBox.shrink()),
          ),
        ),
      );
      expect(GlobalSearchPanel.debugCachedExtractionCount, 0);
    });
  });

  testWidgets('close button has Tooltip and Semantics', (t) async {
    await t.pumpWidget(harness());
    expect(
      find.ancestor(
        of: find.byIcon(Icons.close),
        matching: find.byType(Tooltip),
      ),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel('Close search all tabs'),
      findsOneWidget,
    );
  });
}
