import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart' show QuillEditor;
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:provider/provider.dart';
import 'package:scrib_desktop/providers/editor_provider.dart';
import 'package:scrib_desktop/services/file_service.dart';
import 'package:scrib_desktop/services/settings_service.dart';
import 'package:scrib_desktop/widgets/editor_widget.dart';

/// Regression tests for the stale-controller bug: ScribEditor used to track
/// the active tab by INDEX, but EditorProvider.closeTab promotes the successor
/// tab to the SAME index when the active tab closes, so the editor stayed
/// bound to the closed tab's (disposed) controller — showing its content and
/// routing edits into the wrong tab. The editor is now keyed by tab identity.
void main() {
  late Directory tmp;
  late SettingsService settings;
  late EditorProvider editor;
  late FileService fs;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('scrib_editor_identity_');
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

  Widget harness(GlobalKey<ScribEditorState> key) => MaterialApp(
        home: MultiProvider(
          providers: [
            ChangeNotifierProvider<EditorProvider>.value(value: editor),
            ChangeNotifierProvider<SettingsService>.value(value: settings),
          ],
          child: Scaffold(body: ScribEditor(key: key)),
        ),
      );

  testWidgets(
      'closing the active plain tab rebinds the TextField to the successor '
      'that lands at the same index', (t) async {
    editor.activeTab!.controller.text = 'AAA content';
    editor.addNewTab();
    editor.activeTab!.controller.text = 'BBB content';
    editor.setActiveTab(0);

    final key = GlobalKey<ScribEditorState>();
    await t.pumpWidget(harness(key));
    expect(
      t.widget<TextField>(find.byType(TextField)).controller,
      same(editor.tabs[0].controller),
    );
    expect(find.text('AAA content'), findsOneWidget);

    final survivor = editor.tabs[1];
    editor.closeTab(0); // successor lands at index 0 — index does not change
    await t.pump();

    expect(editor.activeTab, same(survivor));
    expect(
      t.widget<TextField>(find.byType(TextField)).controller,
      same(survivor.controller),
      reason: 'editor must rebind to the surviving tab, not keep the closed '
          "tab's disposed controller",
    );
    expect(find.text('BBB content'), findsOneWidget);
    expect(find.text('AAA content'), findsNothing);
  });

  testWidgets(
      'closing the active rich tab rebuilds the QuillController from the '
      'successor tab', (t) async {
    editor.activeTab!.controller.text = 'AAA rich';
    editor.toggleEditorMode(); // plain -> rich
    editor.addNewTab();
    editor.activeTab!.controller.text = 'BBB rich';
    editor.toggleEditorMode();
    editor.setActiveTab(0);

    final key = GlobalKey<ScribEditorState>();
    await t.pumpWidget(harness(key));
    await t.pump(); // rich builds are deferred one frame
    expect(
      key.currentState!.quillController!.document.toPlainText(),
      contains('AAA rich'),
    );

    final survivor = editor.tabs[1];
    editor.closeTab(0);
    await t.pump(); // placeholder frame for the successor
    await t.pump(); // real editor frame

    expect(editor.activeTab, same(survivor));
    final doc = key.currentState!.quillController!.document.toPlainText();
    expect(doc, contains('BBB rich'),
        reason: 'quill controller must hold the surviving tab\'s document');
    expect(doc, isNot(contains('AAA rich')));
    expect(t.takeException(), isNull);
  });

  testWidgets(
      'replacing a single empty untitled tab via openFile rebinds the editor',
      (t) async {
    final path = '${tmp.path}${Platform.pathSeparator}note.txt';

    final key = GlobalKey<ScribEditorState>();
    await t.pumpWidget(harness(key));

    // Real file IO never completes inside the widget-test FakeAsync zone —
    // run it (and openFile, which reads the file back) under runAsync.
    await t.runAsync(() async {
      await File(path).writeAsString('from disk');
      // openFile swaps a new tab in at index 0 (same index, same mode).
      await editor.openFile(path);
    });
    await t.pump();

    expect(
      t.widget<TextField>(find.byType(TextField)).controller,
      same(editor.tabs[0].controller),
    );
    expect(find.text('from disk'), findsOneWidget);
  });

  testWidgets(
      'app-level shortcuts win over flutter_quill defaults while the rich '
      'editor has focus', (t) async {
    editor.activeTab!.controller.text = 'hello world';
    editor.toggleEditorMode(); // rich

    bool ctrlFReachedApp = false;
    bool saveAsReachedApp = false;
    final key = GlobalKey<ScribEditorState>();
    await t.pumpWidget(MaterialApp(
      home: MultiProvider(
        providers: [
          ChangeNotifierProvider<EditorProvider>.value(value: editor),
          ChangeNotifierProvider<SettingsService>.value(value: settings),
        ],
        child: Scaffold(
          body: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.keyF, control: true):
                  () => ctrlFReachedApp = true,
              const SingleActivator(LogicalKeyboardKey.keyS,
                  control: true, shift: true): () => saveAsReachedApp = true,
            },
            child: ScribEditor(key: key),
          ),
        ),
      ),
    ));
    await t.pump(); // deferred rich build

    // Focus the rich editor directly (a bare tap does not reliably focus the
    // quill render editor inside the test harness).
    t.widget<QuillEditor>(find.byType(QuillEditor)).focusNode.requestFocus();
    await t.pump();
    expect(
      FocusManager.instance.primaryFocus,
      same(t.widget<QuillEditor>(find.byType(QuillEditor)).focusNode),
      reason: 'precondition: the rich editor must own focus',
    );

    // Ctrl+F: quill's default would open its own search dialog and consume
    // the event before MainScreen ever saw it.
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.keyF);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.pump();
    expect(ctrlFReachedApp, isTrue,
        reason: 'Ctrl+F must bubble past the quill editor to the app binding');

    // Ctrl+Shift+S: quill's default applied strikethrough instead of Save As.
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.keyS);
    await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.pump();
    expect(saveAsReachedApp, isTrue,
        reason: 'Ctrl+Shift+S must reach the app (Save As), not strikethrough');
    // And the document must not have been formatted by quill.
    expect(
      key.currentState!.quillController!.document
          .toDelta()
          .toJson()
          .toString(),
      isNot(contains('strike')),
    );
  });

  testWidgets('unknown embed type renders a placeholder instead of crashing',
      (t) async {
    editor.toggleEditorMode(); // rich
    editor.activeTab!.deltaJson = jsonEncode([
      {
        'insert': {'video': 'https://example.com/x'}
      },
      {'insert': '\n'},
    ]);

    final key = GlobalKey<ScribEditorState>();
    await t.pumpWidget(harness(key));
    await t.pump(); // deferred rich build

    expect(t.takeException(), isNull,
        reason: 'an unregistered embed type must not crash the editor build');
    expect(find.text('Unsupported content'), findsOneWidget);
  });
}
