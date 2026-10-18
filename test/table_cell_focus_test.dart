import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:provider/provider.dart';
import 'package:scrib_desktop/providers/editor_provider.dart';
import 'package:scrib_desktop/services/file_service.dart';
import 'package:scrib_desktop/services/settings_service.dart';
import 'package:scrib_desktop/services/table_embed.dart';
import 'package:scrib_desktop/widgets/editor_widget.dart';
import 'package:scrib_desktop/widgets/table_embed_builder.dart';

/// A table cell's text was replaced by the whole note: type in a cell, click
/// the empty editor area below the content, press Ctrl+End, and the cell held
/// the note as plain text (U+FFFC for embeds); saving kept it.
///
/// Cells sat inside the rich editor's focus subtree, so the editor's focus node
/// reported hasFocus while a CELL had primary focus. flutter_quill then treated
/// itself as focused: a click on the editor area asked for the keyboard without
/// taking focus from the cell, attaching quill's text-input client (carrying
/// the full note) while the cell still received keys. Its "transparent" tap
/// recognizer also handled every click on a cell, which is why the first click
/// on a fresh table typed into the note instead of the cell.
///
/// These tests drive the real ScribEditor and play the platform's part through
/// TestTextInput: text arrives for whichever client attached last, against the
/// editing state the platform was last given, as the Windows engine does.
void main() {
  late Directory tmp;
  late SettingsService settings;
  late EditorProvider editor;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('scrib_table_focus_');
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

  Widget harness(GlobalKey<ScribEditorState> key) => MaterialApp(
        home: MultiProvider(
          providers: [
            ChangeNotifierProvider<EditorProvider>.value(value: editor),
            ChangeNotifierProvider<SettingsService>.value(value: settings),
          ],
          // Tight constraints, as MainScreen's Expanded gives the editor, so
          // the editor's area runs below the content.
          child: Scaffold(body: SizedBox.expand(child: ScribEditor(key: key))),
        ),
      );

  /// Two typed lines followed by a 2x2 table, as in the bug report.
  Future<QuillController> pumpNoteWithTable(
    WidgetTester t,
    GlobalKey<ScribEditorState> key,
  ) async {
    final scratch = QuillController.basic();
    scratch.replaceText(0, 0, 'first line\nsecond line\n', null);
    scratch.updateSelection(
      TextSelection.collapsed(offset: scratch.document.length - 1),
      ChangeSource.local,
    );
    insertTableEmbed(scratch, ScribTable.empty(rows: 2, cols: 2, id: 'tf'));
    editor.toggleEditorMode(); // plain -> rich
    editor.activeTab!.deltaJson =
        jsonEncode(scratch.document.toDelta().toJson());
    scratch.dispose();

    await t.pumpWidget(harness(key));
    await t.pump(); // rich builds are deferred one frame
    await t.pump();
    return key.currentState!.quillController!;
  }

  FocusNode quillFocus(WidgetTester t) =>
      t.widget<QuillEditor>(find.byType(QuillEditor)).focusNode;

  Finder cell(int index) => find
      .descendant(
        of: find.byType(QuillEditor),
        matching: find.byType(TextField),
      )
      .at(index);

  FocusNode cellFocus(WidgetTester t, int index) =>
      t.widget<TextField>(cell(index)).focusNode!;

  String cellText(WidgetTester t, int index) =>
      t.widget<TextField>(cell(index)).controller!.text;

  ScribTable tableIn(QuillController c) {
    late ScribTable found;
    visitDocumentEmbeds(c.document, (offset, embed) {
      final parsed = tableFromEmbed(embed);
      if (parsed == null) return true;
      found = parsed;
      return false;
    });
    return found;
  }

  /// Plays the platform: inserts [text] at the selection of the editing state
  /// the platform holds, and reports it to the client that attached last.
  Future<void> platformTypes(WidgetTester t, String text) async {
    final state = t.testTextInput.editingState;
    expect(state, isNotNull, reason: 'no text-input client is attached');
    final value = TextEditingValue.fromJSON(state!);
    final at = value.selection.isValid
        ? value.selection.extentOffset
        : value.text.length;
    final next = value.text.replaceRange(at, at, text);
    t.testTextInput.updateEditingValue(TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: at + text.length),
    ));
    await t.pump();
  }

  /// Clicks the line of plain text above the table.
  Future<void> clickFirstLine(WidgetTester t) async {
    final box = t.getRect(find.byType(QuillEditor));
    await t.tapAt(box.topLeft + const Offset(40, 26));
    await t.pump();
  }

  /// Clicks the empty editor area below the table.
  Future<void> clickBelowContent(WidgetTester t) async {
    final box = t.getRect(find.byType(QuillEditor));
    await t.tapAt(Offset(box.center.dx, box.bottom - 20));
    await t.pump();
  }

  // A click on the note straight before the click on the cell is read by
  // quill as a double-click: it moves its own selection, which used to make it
  // take focus back from the cell as the cell took it.
  for (final gap in const [Duration(milliseconds: 600), Duration.zero]) {
    testWidgets(
        'the first click on a table cell focuses it and typing lands in the '
        'cell, not the note (${gap.inMilliseconds} ms after a click on the '
        'note)', (t) async {
      final key = GlobalKey<ScribEditorState>();
      final controller = await pumpNoteWithTable(t, key);
      await clickFirstLine(t);
      expect(quillFocus(t).hasPrimaryFocus, isTrue,
          reason: 'precondition: the note itself is being edited');
      final noteBefore = controller.document.toPlainText();
      await t.pump(gap);

      await t.tap(cell(0));
      await t.pump();

      expect(cellFocus(t, 0).hasPrimaryFocus, isTrue);
      expect(quillFocus(t).hasFocus, isFalse,
          reason: 'while a cell is focused the rich editor must not consider '
              'itself focused, or it attaches its own text-input client');

      await platformTypes(t, 'a');
      expect(cellText(t, 0), 'a');
      expect(controller.document.toPlainText(), noteBefore,
          reason: 'the letter typed into the cell must not reach the note');
    });
  }

  testWidgets(
      'clicking below the content after editing a cell hands focus back to the '
      'note, and Ctrl+End then Enter never copy the note into the cell',
      (t) async {
    final key = GlobalKey<ScribEditorState>();
    final controller = await pumpNoteWithTable(t, key);

    await t.tap(cell(0));
    await t.pump();
    await t.tap(cell(0)); // the old build needed a second click to focus
    await t.pump();
    await platformTypes(t, 'H');
    expect(cellText(t, 0), 'H', reason: 'precondition: the cell took input');
    await t.pump(const Duration(milliseconds: 600)); // debounced commit
    expect(tableIn(controller).cellAt(0, 0), 'H');

    await clickBelowContent(t);
    expect(quillFocus(t).hasPrimaryFocus, isTrue,
        reason: 'a click on the editor area must take focus from the cell');
    expect(cellFocus(t, 0).hasFocus, isFalse);

    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.end);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.pump();
    await platformTypes(t, '\n'); // the Windows engine applies Enter itself
    await t.pump(const Duration(milliseconds: 600));

    expect(cellText(t, 0), 'H',
        reason: 'the cell must keep exactly what was typed into it');
    expect(tableIn(controller).cellAt(0, 0), 'H',
        reason: 'the saved table must not carry the note text');
    expect(controller.document.toPlainText(), contains('first line'));
  });

  testWidgets('Tab pressed in a cell never inserts a tab into the note',
      (t) async {
    final key = GlobalKey<ScribEditorState>();
    final controller = await pumpNoteWithTable(t, key);
    await clickFirstLine(t);

    await t.tap(cell(0));
    await t.pump();
    await t.tap(cell(0));
    await t.pump();
    expect(cellFocus(t, 0).hasPrimaryFocus, isTrue);

    await t.sendKeyEvent(LogicalKeyboardKey.tab);
    await t.pump();

    expect(controller.document.toPlainText(), isNot(contains('\t')),
        reason: "the rich editor's Tab handler must not see a cell's keys");
  });
}
