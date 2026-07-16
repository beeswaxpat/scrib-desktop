import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:provider/provider.dart';
import 'package:scrib_desktop/constants.dart';
import 'package:scrib_desktop/dialogs/password_dialog.dart';
import 'package:scrib_desktop/providers/editor_provider.dart';
import 'package:scrib_desktop/services/file_service.dart';
import 'package:scrib_desktop/services/settings_service.dart';
import 'package:scrib_desktop/widgets/status_bar_widget.dart';

/// Widget tests for the pieces that pump cleanly in the default test harness:
/// the status bar and the password dialogs. (MainScreen itself pulls in
/// window_manager and is exercised through the provider/service unit tests.)
void main() {
  group('ScribStatusBar', () {
    late Directory tmp;
    late SettingsService settings;
    late EditorProvider editor;
    late FileService fs;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('scrib_widget_');
      settings = SettingsService();
      await settings.initForTests(tmp.path);
      fs = FileService();
      editor = EditorProvider(fs, settings);
    });

    tearDown(() async {
      editor.dispose();
      await Hive.close();
      try { await tmp.delete(recursive: true); } catch (_) {}
    });

    // The status bar is a single horizontal Row sized for a real window; give
    // the test surface enough width that it doesn't overflow.
    Future<void> pumpWide(WidgetTester t, Widget w) async {
      await t.binding.setSurfaceSize(const Size(1400, 800));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(w);
    }

    Widget harness() => MaterialApp(
          home: ChangeNotifierProvider<EditorProvider>.value(
            value: editor,
            child: const Scaffold(body: ScribStatusBar()),
          ),
        );

    testWidgets('renders zeroed counts for an empty tab', (t) async {
      await pumpWide(t, harness());
      expect(find.text('Words: 0'), findsOneWidget);
      expect(find.text('Characters: 0'), findsOneWidget);
      expect(find.text('Lines: 1'), findsOneWidget);
    });

    testWidgets('renders correct counts after text is set', (t) async {
      editor.activeTab!.controller.text = 'hello world here';
      editor.invalidateTextCache();
      await pumpWide(t, harness());
      expect(find.text('Words: 3'), findsOneWidget);
      expect(find.text('Characters: 16'), findsOneWidget);
    });

    testWidgets('shows Plain Text in plain mode', (t) async {
      await pumpWide(t, harness());
      expect(find.text('Plain Text'), findsOneWidget);
      expect(find.text('Rich Text'), findsNothing);
    });

    testWidgets('shows Rich Text after toggling to rich mode', (t) async {
      editor.toggleEditorMode();
      await pumpWide(t, harness());
      expect(find.text('Rich Text'), findsOneWidget);
    });

    testWidgets('shows .txt label and open lock for an unencrypted txt tab', (t) async {
      editor.activeTab!.filePath = '${tmp.path}${Platform.pathSeparator}note.txt';
      editor.setActiveTab(0);
      await pumpWide(t, harness());
      expect(find.text('.txt'), findsOneWidget);
      expect(find.byIcon(Icons.lock_open), findsOneWidget);
    });

    testWidgets('shows .rtf label when the file path ends in .rtf', (t) async {
      editor.activeTab!.filePath = '${tmp.path}${Platform.pathSeparator}doc.rtf';
      editor.setActiveTab(0);
      await pumpWide(t, harness());
      expect(find.text('.rtf'), findsOneWidget);
    });

    testWidgets('shows the gold lock and Encrypted label when encrypted', (t) async {
      editor.toggleEncryption();
      await pumpWide(t, harness());
      expect(find.byIcon(Icons.lock), findsOneWidget);
      expect(find.text('Encrypted (.scrb)'), findsOneWidget);
    });

    testWidgets('renders the app version from constants', (t) async {
      await pumpWide(t, harness());
      expect(find.text('Scrib v$appVersion'), findsOneWidget);
    });

    testWidgets('shows untitled for a never-saved tab', (t) async {
      await pumpWide(t, harness());
      expect(find.text('untitled'), findsOneWidget);
      expect(find.text('.txt'), findsNothing);
    });

    testWidgets('shows the actual extension for non-txt files', (t) async {
      editor.activeTab!.filePath = '${tmp.path}${Platform.pathSeparator}notes.md';
      editor.setActiveTab(0);
      await pumpWide(t, harness());
      expect(find.text('.md'), findsOneWidget);
      expect(find.text('.txt'), findsNothing);
    });

    testWidgets('shows Ln, Col for the caret in a plain text tab', (t) async {
      editor.activeTab!.controller.text = 'one\ntwo\nthree';
      editor.invalidateTextCache();
      await pumpWide(t, harness());
      expect(find.text('Ln 1, Col 1'), findsOneWidget);

      // Move the caret to line 2, column 3 ("tw|o" = offset 6).
      editor.activeTab!.controller.selection =
          const TextSelection.collapsed(offset: 6);
      await t.pump();
      expect(find.text('Ln 2, Col 3'), findsOneWidget);
    });

    test('formatLabel derives labels from the real path', () {
      expect(ScribStatusBar.formatLabel(null), 'untitled');
      expect(ScribStatusBar.formatLabel(r'C:\notes\a.md'), '.md');
      expect(ScribStatusBar.formatLabel(r'C:\notes\data.JSON'), '.json');
      expect(ScribStatusBar.formatLabel(r'C:\notes\doc.rtf'), '.rtf');
      expect(ScribStatusBar.formatLabel(r'C:\notes\noext'), 'file');
      // A dot in a folder name must not read as an extension.
      expect(ScribStatusBar.formatLabel(r'C:\my.folder\noext'), 'file');
    });

    test('caretLineCol is 1-based and newline-aware', () {
      final c = TextEditingController(text: 'ab\ncd');
      c.selection = const TextSelection.collapsed(offset: 0);
      expect(ScribStatusBar.caretLineCol(c), (1, 1));
      c.selection = const TextSelection.collapsed(offset: 2);
      expect(ScribStatusBar.caretLineCol(c), (1, 3));
      c.selection = const TextSelection.collapsed(offset: 3);
      expect(ScribStatusBar.caretLineCol(c), (2, 1));
      c.selection = const TextSelection.collapsed(offset: 5);
      expect(ScribStatusBar.caretLineCol(c), (2, 3));
      c.dispose();
    });
  });

  group('password dialogs', () {
    Widget launcher(Future<void> Function(BuildContext) onTap) => MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => ElevatedButton(
                onPressed: () => onTap(ctx),
                child: const Text('go'),
              ),
            ),
          ),
        );

    testWidgets('password prompt pops with the entered value', (t) async {
      String? captured = '__none__';
      await t.pumpWidget(launcher((ctx) async {
        captured = await showPasswordPrompt(ctx, title: 'Enter', message: 'msg');
      }));
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField), 'hunter2-secret');
      await t.tap(find.text('Open'));
      await t.pumpAndSettle();
      expect(captured, 'hunter2-secret');
    });

    testWidgets('password prompt with empty input does not pop', (t) async {
      String? captured = '__none__';
      await t.pumpWidget(launcher((ctx) async {
        captured = await showPasswordPrompt(ctx, title: 'Enter', message: 'msg');
      }));
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
      await t.tap(find.text('Open'));
      await t.pumpAndSettle();
      // Still open, future not completed.
      expect(find.text('Open'), findsOneWidget);
      expect(captured, '__none__');
    });

    testWidgets('password prompt Cancel returns null', (t) async {
      String? captured = '__none__';
      await t.pumpWidget(launcher((ctx) async {
        captured = await showPasswordPrompt(ctx, title: 'Enter', message: 'msg');
      }));
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();
      expect(captured, isNull);
    });

    testWidgets('visibility toggle flips the reveal icon', (t) async {
      await t.pumpWidget(launcher((ctx) async {
        await showPasswordPrompt(ctx, title: 'Enter', message: 'msg');
      }));
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
      expect(find.byIcon(Icons.visibility_off), findsOneWidget);
      await t.tap(find.byIcon(Icons.visibility_off));
      await t.pumpAndSettle();
      expect(find.byIcon(Icons.visibility), findsOneWidget);
    });

    testWidgets('set-password rejects an empty password', (t) async {
      await t.pumpWidget(launcher((ctx) async {
        await showSetPasswordDialog(ctx);
      }));
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
      await t.tap(find.text('Encrypt'));
      await t.pumpAndSettle();
      expect(find.text('Password cannot be empty'), findsOneWidget);
    });

    testWidgets('set-password rejects a password shorter than 8 chars', (t) async {
      await t.pumpWidget(launcher((ctx) async {
        await showSetPasswordDialog(ctx);
      }));
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField).at(0), 'short');
      await t.enterText(find.byType(TextField).at(1), 'short');
      await t.tap(find.text('Encrypt'));
      await t.pumpAndSettle();
      expect(find.text('Password must be at least 8 characters'), findsOneWidget);
    });

    testWidgets('set-password rejects mismatched confirmation', (t) async {
      await t.pumpWidget(launcher((ctx) async {
        await showSetPasswordDialog(ctx);
      }));
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField).at(0), 'longenough1');
      await t.enterText(find.byType(TextField).at(1), 'different22');
      await t.tap(find.text('Encrypt'));
      await t.pumpAndSettle();
      expect(find.text('Passwords do not match'), findsOneWidget);
    });

    testWidgets('set-password accepts matching 8+ char passwords', (t) async {
      String? captured = '__none__';
      await t.pumpWidget(launcher((ctx) async {
        captured = await showSetPasswordDialog(ctx);
      }));
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField).at(0), 'correct-horse');
      await t.enterText(find.byType(TextField).at(1), 'correct-horse');
      await t.tap(find.text('Encrypt'));
      await t.pumpAndSettle();
      expect(captured, 'correct-horse');
    });
  });
}
