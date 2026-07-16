import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:hive/hive.dart';
import 'package:provider/provider.dart';
import 'package:scrib_desktop/providers/editor_provider.dart';
import 'package:scrib_desktop/services/file_service.dart';
import 'package:scrib_desktop/services/settings_service.dart';
import 'package:scrib_desktop/services/table_embed.dart';
import 'package:scrib_desktop/widgets/search_bar_widget.dart';

/// Rich-mode find/replace must treat match indices as QUILL DOCUMENT offsets:
/// every embed (image/table) occupies exactly one position in the document,
/// so search text that strips embeds shifts every following match and lets
/// Replace / Replace All destroy embeds and mangle neighbouring characters.
/// These tests pin the offset-faithful behavior around embeds, plus the
/// match-verify guard, Shift+Enter/F3 navigation, the option toggles, and
/// selection prefill.
void main() {
  const obj = '￼'; // object replacement char: an embed in plain text
  const imgA = 'data:image/png;base64,aW1nQQ==';
  const imgB = 'data:image/png;base64,aW1nQg==';

  late Directory tmp;
  late SettingsService settings;
  late FileService fs;
  late EditorProvider editor;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('scrib_search_');
    settings = SettingsService();
    await settings.initForTests(tmp.path);
    fs = FileService();
    editor = EditorProvider(fs, settings);
    ScribSearchBar.resetSearchOptions();
  });

  tearDown(() async {
    editor.dispose();
    await Hive.close();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<QuillController> pumpRichBar(
    WidgetTester tester, {
    required List<Map<String, dynamic>> ops,
    TextSelection? selection,
  }) async {
    final tab = editor.activeTab!;
    tab.mode = EditorMode.richText;
    tab.deltaJson = jsonEncode(ops);
    final qc = QuillController(
      document: Document.fromJson(ops),
      selection: selection ?? const TextSelection.collapsed(offset: 0),
    );
    addTearDown(qc.dispose);
    editor.openFindReplace();
    await tester.pumpWidget(
      MaterialApp(
        home: ChangeNotifierProvider<EditorProvider>.value(
          value: editor,
          child: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: ScribSearchBar(quillController: qc),
            ),
          ),
        ),
      ),
    );
    await tester.pump(); // run the post-frame init (pending query / prefill)
    return qc;
  }

  Future<void> pumpPlainBar(WidgetTester tester, String text) async {
    final tab = editor.activeTab!;
    tab.controller.text = text;
    editor.openFindReplace();
    await tester.pumpWidget(
      MaterialApp(
        home: ChangeNotifierProvider<EditorProvider>.value(
          value: editor,
          child: const Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: ScribSearchBar(),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> setQuery(WidgetTester tester, String q) async {
    await tester.enterText(find.byType(TextField).first, q);
    await tester.pump();
  }

  Future<void> setReplacement(WidgetTester tester, String r) async {
    await tester.enterText(find.byType(TextField).at(1), r);
    await tester.pump();
  }

  Future<void> tapReplace(WidgetTester tester) async {
    // 'Replace' appears twice (row label + button); the button is last.
    await tester.tap(find.text('Replace').last);
    await tester.pump();
  }

  Future<void> tapReplaceAll(WidgetTester tester) async {
    await tester.tap(find.text('All'));
    await tester.pump();
  }

  Future<void> pressEnter(WidgetTester tester) async {
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
  }

  int countEmbeds(QuillController qc, String key) {
    var count = 0;
    for (final op in qc.document.toDelta().toList()) {
      final d = op.data;
      if (d is Map && d.containsKey(key)) count++;
    }
    return count;
  }

  group('offset-faithful replace around embeds', () {
    testWidgets('replace after an image embed targets the right characters',
        (tester) async {
      final qc = await pumpRichBar(tester, ops: [
        {'insert': {'image': imgA}},
        {'insert': ' cat mat\n'},
      ]);
      await setQuery(tester, 'cat');
      await setReplacement(tester, 'dog');

      await tapReplace(tester); // collapsed selection: navigates to the match
      expect(qc.document.toPlainText(), '$obj cat mat\n');
      expect(qc.selection.start, 2);
      expect(qc.selection.end, 5);

      await tapReplace(tester); // now replaces the verified match
      expect(qc.document.toPlainText(), '$obj dog mat\n');
      expect(countEmbeds(qc, 'image'), 1);

      // Let the provider's 150ms content debounce fire before teardown.
      await tester.pump(const Duration(milliseconds: 200));
    });

    testWidgets('replace-all with embeds before, between and after matches',
        (tester) async {
      final qc = await pumpRichBar(tester, ops: [
        {'insert': 'cat '},
        {'insert': {'image': imgA}},
        {'insert': ' cat\ncat '},
        {'insert': {'image': imgB}},
        {'insert': '\n'},
      ]);
      await setQuery(tester, 'cat');
      await setReplacement(tester, 'bird');
      await tapReplaceAll(tester);

      expect(qc.document.toPlainText(), 'bird $obj bird\nbird $obj\n');
      expect(countEmbeds(qc, 'image'), 2);
    });

    testWidgets('replace-all with no matches leaves the document untouched',
        (tester) async {
      final qc = await pumpRichBar(tester, ops: [
        {'insert': {'image': imgA}},
        {'insert': 'cat\n'},
      ]);
      final before = qc.document.toPlainText();
      await setQuery(tester, 'zebra');
      await setReplacement(tester, 'x');
      await tapReplaceAll(tester);
      expect(qc.document.toPlainText(), before);
      expect(countEmbeds(qc, 'image'), 1);
      expect(find.text('0 results'), findsOneWidget);
    });

    testWidgets(
        'replace refuses a selection that does not match the query and '
        'navigates to a real match instead', (tester) async {
      final qc = await pumpRichBar(
        tester,
        ops: [
          {'insert': 'abc cat\n'},
        ],
        selection: const TextSelection(baseOffset: 0, extentOffset: 3),
      );
      await setQuery(tester, 'cat');
      await setReplacement(tester, 'dog');
      await tapReplace(tester);

      expect(qc.document.toPlainText(), 'abc cat\n'); // nothing replaced
      expect(qc.selection.start, 4); // navigated to the actual match
      expect(qc.selection.end, 7);
    });

    testWidgets('replace never destroys an embed covered by the selection',
        (tester) async {
      final qc = await pumpRichBar(
        tester,
        ops: [
          {'insert': {'image': imgA}},
          {'insert': 'cat\n'},
        ],
        // Selection of length 3 covering [embed]'ca' — same length as the
        // query, but not the query text.
        selection: const TextSelection(baseOffset: 0, extentOffset: 3),
      );
      await setQuery(tester, 'cat');
      await setReplacement(tester, 'dog');
      await tapReplace(tester);

      expect(countEmbeds(qc, 'image'), 1);
      expect(qc.document.toPlainText(), '${obj}cat\n');
      expect(qc.selection.start, 1); // navigated to the real match instead
      expect(qc.selection.end, 4);
    });
  });

  group('table cell matches', () {
    testWidgets('are counted and navigable (selects the table embed), '
        'and replace-all leaves table content alone', (tester) async {
      final table = ScribTable.empty(rows: 1, cols: 2, id: 'tt')
          .withCell(0, 0, 'cat')
          .withCell(0, 1, 'dog');
      final qc = await pumpRichBar(tester, ops: [
        {'insert': 'cat\n'},
        {'insert': table.toEmbed().toJson()},
        {'insert': '\n'},
      ]);
      await setQuery(tester, 'cat');
      expect(find.text('1/2'), findsOneWidget); // text match + table match

      await pressEnter(tester); // first: the text match
      expect(qc.selection.start, 0);
      expect(qc.selection.end, 3);

      await pressEnter(tester); // second: the table embed gets selected
      expect(qc.selection.start, 4);
      expect(qc.selection.end, 5);

      await pressEnter(tester); // wraps back to the first match
      expect(qc.selection.start, 0);

      await setReplacement(tester, 'bird');
      await tapReplaceAll(tester);
      expect(qc.document.toPlainText(), 'bird\n$obj\n');
      final parsed = ScribTable.fromCustomEmbedData(
          (qc.document.toDelta().toList()[1].data as Map)['custom']);
      expect(parsed!.cellAt(0, 0), 'cat'); // untouched
    });
  });

  group('find options', () {
    testWidgets('match case toggle narrows matches and replace-all honors it',
        (tester) async {
      final qc = await pumpRichBar(tester, ops: [
        {'insert': 'Cat cat\n'},
      ]);
      await setQuery(tester, 'cat');
      expect(find.text('1/2'), findsOneWidget);

      await tester.tap(find.text('Aa'));
      await tester.pump();
      expect(find.text('1/1'), findsOneWidget);

      await setReplacement(tester, 'dog');
      await tapReplaceAll(tester);
      expect(qc.document.toPlainText(), 'Cat dog\n');
    });

    testWidgets('whole word toggle excludes substring matches',
        (tester) async {
      final qc = await pumpRichBar(tester, ops: [
        {'insert': 'cat catalog\n'},
      ]);
      await setQuery(tester, 'cat');
      expect(find.text('1/2'), findsOneWidget);

      await tester.tap(find.text('|ab|'));
      await tester.pump();
      expect(find.text('1/1'), findsOneWidget);

      await setReplacement(tester, 'dog');
      await tapReplaceAll(tester);
      expect(qc.document.toPlainText(), 'dog catalog\n');
    });
  });

  group('keyboard navigation', () {
    testWidgets('Shift+Enter finds the PREVIOUS match (tooltip promise)',
        (tester) async {
      final qc = await pumpRichBar(tester, ops: [
        {'insert': 'cat cat cat\n'},
      ]);
      // Tooltip unchanged; the handler must now actually honor it.
      expect(
          find.byTooltip('Previous match (Shift+Enter)'), findsOneWidget);

      await setQuery(tester, 'cat');
      await pressEnter(tester);
      expect(qc.selection.start, 0);
      await pressEnter(tester);
      expect(qc.selection.start, 4);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(qc.selection.start, 0); // went back
    });

    testWidgets('F3 / Shift+F3 cycle next / previous inside the bar',
        (tester) async {
      final qc = await pumpRichBar(tester, ops: [
        {'insert': 'cat cat cat\n'},
      ]);
      await setQuery(tester, 'cat');

      await tester.sendKeyEvent(LogicalKeyboardKey.f3);
      await tester.pump();
      expect(qc.selection.start, 0);

      await tester.sendKeyEvent(LogicalKeyboardKey.f3);
      await tester.pump();
      expect(qc.selection.start, 4);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.f3);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(qc.selection.start, 0);
    });
  });

  group('selection prefill', () {
    testWidgets('find field is prefilled from the editor selection',
        (tester) async {
      await pumpRichBar(
        tester,
        ops: [
          {'insert': 'hello world\n'},
        ],
        selection: const TextSelection(baseOffset: 0, extentOffset: 5),
      );
      final field = tester.widget<TextField>(find.byType(TextField).first);
      expect(field.controller!.text, 'hello');
      expect(find.text('1/1'), findsOneWidget);
    });

    testWidgets('multi-line and embed selections are not prefilled',
        (tester) async {
      await pumpRichBar(
        tester,
        ops: [
          {'insert': {'image': imgA}},
          {'insert': 'ab\n'},
        ],
        selection: const TextSelection(baseOffset: 0, extentOffset: 3),
      );
      final field = tester.widget<TextField>(find.byType(TextField).first);
      expect(field.controller!.text, isEmpty);
    });
  });

  group('plain-text mode still works with the options', () {
    testWidgets('case-sensitive replace-all preserves other-case occurrences',
        (tester) async {
      await pumpPlainBar(tester, 'cat Cat cat');
      await setQuery(tester, 'cat');
      await tester.tap(find.text('Aa'));
      await tester.pump();
      await setReplacement(tester, 'dog');
      await tapReplaceAll(tester);
      expect(editor.activeTab!.controller.text, 'dog Cat dog');
    });

    testWidgets('replace navigates instead of replacing on mismatched selection',
        (tester) async {
      await pumpPlainBar(tester, 'abc cat');
      final tab = editor.activeTab!;
      tab.controller.selection =
          const TextSelection(baseOffset: 0, extentOffset: 3);
      await setQuery(tester, 'cat');
      await setReplacement(tester, 'dog');
      await tapReplace(tester);
      expect(tab.controller.text, 'abc cat');
      expect(tab.controller.selection.start, 4);
      expect(tab.controller.selection.end, 7);
    });
  });
}
