import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:scrib_desktop/constants.dart';
import 'package:scrib_desktop/providers/editor_provider.dart';
import 'package:scrib_desktop/services/file_service.dart';
import 'package:scrib_desktop/services/rtf_service.dart';
import 'package:scrib_desktop/services/settings_service.dart';

/// Regression + behavior tests added in the hardening pass: the encryption
/// downgrade fix, extension-aware background saves, save-all, secret hygiene,
/// and the open/dirty/mode state machine edges.
void main() {
  late Directory tmp;
  late SettingsService settings;
  late EditorProvider editor;
  late FileService fs;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('scrib_provider2_');
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

  String path(String name) => '${tmp.path}${Platform.pathSeparator}$name';
  EditorTab tab() => editor.activeTab!;

  group('encryption downgrade fix (openScrbFile existing tab)', () {
    test('reopening into a matching tab re-flags it encrypted', () async {
      final p = path('note.scrb');
      await fs.writeScrbFile(p, 'classified', 'pw', iterations: 1000);
      // Simulate a pre-existing tab pointing at this path but flagged plaintext.
      tab().filePath = p;
      tab().isEncrypted = false;
      tab().password = null;

      final ok = await editor.openScrbFile(p, 'pw');
      expect(ok, isTrue);
      expect(editor.activeTab!.isEncrypted, isTrue,
          reason: 'a decrypted .scrb must never be left flagged plaintext');
      expect(editor.activeTab!.password, 'pw');
      expect(editor.activeTab!.controller.text, 'classified');
    });

    test('after reopen, an in-place save stays encrypted', () async {
      final p = path('note2.scrb');
      await fs.writeScrbFile(p, 'classified', 'pw', iterations: 1000);
      tab().filePath = p;
      tab().isEncrypted = false;
      await editor.openScrbFile(p, 'pw');
      editor.activeTab!.controller.text = 'updated classified';
      await editor.saveActiveTab();
      expect(await fs.isScrbFile(p), isTrue);
      expect(await fs.readScrbFile(p, 'pw'), 'updated classified');
    });
  });

  group('extension-aware background save', () {
    test('saveAllSaveable writes a rich .rtf tab as RTF, not the scrib envelope', () async {
      final p = path('doc.rtf');
      await fs.writeRtfFile(p, r'{\rtf1\ansi\deff0 old\par}');
      tab().filePath = p;
      tab().mode = EditorMode.richText;
      tab().deltaJson = '[{"insert":"fresh rich body\\n"}]';
      tab().savedDeltaJson = ''; // dirty

      final allSaved = await editor.saveAllSaveable();
      expect(allSaved, isTrue);
      final rtf = await fs.readRtfFile(p);
      expect(rtf, startsWith(r'{\rtf1'));
      expect(rtf, contains('fresh rich body'));
      expect(rtf, isNot(contains('scrib_rich')));
      // And it must re-import cleanly.
      expect(
        (RtfService.rtfToDelta(rtf)),
        contains('fresh rich body'),
      );
    });

    test('saveAllSaveable writes an encrypted tab as a decryptable .scrb', () async {
      final p = path('enc.scrb');
      tab().filePath = p;
      tab().isEncrypted = true;
      tab().password = 'pw';
      tab().controller.text = 'secret body';
      tab().savedContent = ''; // dirty
      final allSaved = await editor.saveAllSaveable();
      expect(allSaved, isTrue);
      expect(await fs.readScrbFile(p, 'pw'), 'secret body');
    });

    test('saveAllSaveable returns false while a dirty untitled tab remains', () async {
      tab().controller.text = 'unsaved and unnamed';
      expect(tab().filePath, isNull);
      final allSaved = await editor.saveAllSaveable();
      expect(allSaved, isFalse);
      expect(editor.hasUnsavedChanges, isTrue);
    });

    test('saveAllSaveable returns true when nothing is dirty', () async {
      final allSaved = await editor.saveAllSaveable();
      expect(allSaved, isTrue);
    });

    test('saveAllSaveable refuses to write plaintext into an encrypted-no-password tab', () async {
      final p = path('orphan.scrb');
      tab().filePath = p;
      tab().isEncrypted = true;
      tab().password = null; // no key
      tab().controller.text = 'should not be written in clear';
      tab().savedContent = ''; // dirty
      final allSaved = await editor.saveAllSaveable();
      expect(allSaved, isFalse);
      expect(await File(p).exists(), isFalse);
    });
  });

  group('secret hygiene + tab state', () {
    test('closeTab clears the password synchronously', () {
      editor.addNewTab(); // ensure >1 tab so closing index 0 is straightforward
      final closed = editor.tabs[0];
      closed.password = 'super-secret';
      editor.closeTab(0);
      expect(closed.password, isNull);
    });

    test('toggleEncryption flips the flag and clears the password when turning off', () {
      editor.toggleEncryption();
      tab().password = 'pw';
      expect(tab().isEncrypted, isTrue);
      editor.toggleEncryption();
      expect(tab().isEncrypted, isFalse);
      expect(tab().password, isNull);
    });

    test('setTabFontSize clamps to the constant min and max', () {
      editor.setTabFontSize(2);
      expect(tab().tabFontSize, minFontSize);
      editor.setTabFontSize(999);
      expect(tab().tabFontSize, maxFontSize);
    });

    test('hasUnsavedChanges reflects tab dirtiness', () {
      expect(editor.hasUnsavedChanges, isFalse);
      tab().controller.text = 'typed';
      expect(editor.hasUnsavedChanges, isTrue);
    });

    test('setActiveTab ignores an out-of-range index', () {
      editor.setActiveTab(99);
      expect(editor.activeTabIndex, 0);
    });

    test('closeTab returns false for an out-of-range index', () {
      expect(editor.closeTab(-1), isFalse);
      expect(editor.closeTab(99), isFalse);
    });

    test('addNewTab de-dupes the date-stamped name with a counter', () {
      final first = editor.tabs[0].fileName;
      editor.addNewTab();
      expect(editor.tabs[1].fileName, '$first 2');
    });
  });

  group('open + mode state machine', () {
    test('openFile on a .scrb path throws ScribNeedsPasswordException', () {
      expect(
        () => editor.openFile(path('x.scrb')),
        throwsA(isA<ScribNeedsPasswordException>()),
      );
    });

    test('openScrbFile with the wrong password returns false and opens no tab', () async {
      final p = path('wrong.scrb');
      await fs.writeScrbFile(p, 'data', 'right-pw', iterations: 1000);
      final before = editor.tabs.length;
      final ok = await editor.openScrbFile(p, 'wrong-pw');
      expect(ok, isFalse);
      expect(editor.tabs.length, before);
      expect(editor.activeTab!.isEncrypted, isFalse);
    });

    test('openScrbFile with the correct password opens an encrypted tab', () async {
      final p = path('right.scrb');
      await fs.writeScrbFile(p, 'opened', 'pw', iterations: 1000);
      final ok = await editor.openScrbFile(p, 'pw');
      expect(ok, isTrue);
      expect(editor.activeTab!.isEncrypted, isTrue);
      expect(editor.activeTab!.controller.text, 'opened');
    });

    test('openScrbFile with a malformed rich envelope falls back to plain text', () async {
      final p = path('badrich.scrb');
      // Looks like the rich envelope prefix but is not valid JSON.
      await fs.writeScrbFile(p, '$scribRichPrefix not-valid-json', 'pw', iterations: 1000);
      final ok = await editor.openScrbFile(p, 'pw');
      expect(ok, isTrue);
      expect(editor.activeTab!.mode, EditorMode.plainText);
    });

    test('getSaveContent wraps rich-mode content and returns text in plain mode', () {
      tab().controller.text = 'plain body';
      expect(tab().getSaveContent(), 'plain body');
      tab().mode = EditorMode.richText;
      tab().deltaJson = '[{"insert":"x\\n"}]';
      expect(tab().getSaveContent(), startsWith(scribRichPrefix));
    });

    test('toggleEditorMode plain->rich on empty text marks the tab dirty', () {
      expect(tab().isDirty, isFalse);
      editor.toggleEditorMode();
      expect(tab().mode, EditorMode.richText);
      expect(tab().isDirty, isTrue);
      expect(tab().deltaJson, contains('insert'));
    });
  });
}
