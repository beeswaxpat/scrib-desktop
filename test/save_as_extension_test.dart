import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:scrib_desktop/providers/editor_provider.dart';
import 'package:scrib_desktop/services/file_operations.dart';
import 'package:scrib_desktop/services/file_service.dart';
import 'package:scrib_desktop/services/rtf_service.dart';
import 'package:scrib_desktop/services/settings_service.dart';

/// Stands in for the native Save dialog: returns whatever name the "user"
/// typed. The real Windows dialog appends no extension of its own.
class _FakeSavePicker extends FilePicker {
  String? next;

  /// Runs while the "dialog" is open, standing in for clicks on the Scrib
  /// window (the real dialog has no owner, so the window stays usable).
  void Function()? whileOpen;

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async {
    whileOpen?.call();
    return next;
  }
}

/// Issue #25: a rich-text note saved under a name typed without an extension
/// (or as .txt) was refused by every write path and never reached disk.
void main() {
  final sep = Platform.pathSeparator;

  group('FileOperations.saveAsTarget', () {
    String t(String p, {bool encrypted = false, bool rich = false}) =>
        FileOperations.saveAsTarget('C:${sep}notes$sep$p',
            encrypted: encrypted, rich: rich);
    String p(String name) => 'C:${sep}notes$sep$name';

    test('rich text gets .rtf', () {
      expect(t('Meeting', rich: true), p('Meeting.rtf'));
      expect(t('Meeting.txt', rich: true), p('Meeting.rtf'));
      expect(t('Meeting.RTF', rich: true), p('Meeting.RTF'));
      expect(t('Minutes 10.17', rich: true), p('Minutes 10.17.rtf'));
    });

    test('plain text gets .txt only when it needs one', () {
      expect(t('Meeting'), p('Meeting.txt'));
      expect(t('Meeting.txt'), p('Meeting.txt'));
      expect(t('Meeting.rtf'), p('Meeting.txt'));
      expect(t('README.md'), p('README.md'));
    });

    test('encrypted tabs always land in a .scrb', () {
      expect(t('Secret', encrypted: true), p('Secret.scrb'));
      expect(t('Secret.txt', encrypted: true, rich: true), p('Secret.scrb'));
      expect(t('Secret.scrb', encrypted: true), p('Secret.scrb'));
    });

    test('picking .scrb still means an encrypted copy', () {
      expect(t('Copy.scrb'), p('Copy.scrb'));
      expect(t('Copy.scrb', rich: true), p('Copy.scrb'));
    });

    test('trailing dots and spaces are dropped, as Windows does', () {
      expect(t('Meeting.'), p('Meeting.txt'));
      expect(t('Meeting. ', rich: true), p('Meeting.rtf'));
    });

    test('forward slashes in the path are handled', () {
      expect(
          FileOperations.saveAsTarget('C:/v1.2/Meeting',
              encrypted: false, rich: false),
          'C:/v1.2/Meeting.txt');
    });
  });

  group('saveAs end to end', () {
    late Directory tmp;
    late SettingsService settings;
    late EditorProvider editor;
    late FileService fs;
    late FileOperations ops;
    late _FakeSavePicker picker;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('scrib_saveas_');
      settings = SettingsService();
      await settings.initForTests(tmp.path);
      fs = FileService();
      editor = EditorProvider(fs, settings);
      ops = FileOperations(fs, settings);
      picker = _FakeSavePicker();
      FilePicker.platform = picker;
    });

    tearDown(() async {
      editor.dispose();
      await Hive.close();
      try { await tmp.delete(recursive: true); } catch (_) {}
    });

    String path(String name) => '${tmp.path}$sep$name';
    EditorTab tab() => editor.activeTab!;

    void makeRich(String body) {
      editor.toggleEditorMode();
      editor.updateDeltaJson(
          '[{"insert":"$body"},{"insert":"\\n","attributes":{"header":1}}]');
    }

    test('rich note saved under a name with no extension is written as .rtf',
        () async {
      makeRich('Groceries');
      picker.next = path('Groceries');

      final r = await ops.saveAs(editor, resolvePassword: () async => null);

      expect(r.ok, isTrue, reason: 'error: ${r.error}');
      expect(r.newPath, path('Groceries.rtf'));
      expect(r.extensionChanged, isTrue);
      final rtf = await fs.readRtfFile(path('Groceries.rtf'));
      expect(rtf, startsWith(r'{\rtf1'));
      expect(rtf, contains('Groceries'));
      expect(rtf, isNot(contains('scrib_rich')));
      expect(tab().filePath, path('Groceries.rtf'));
      expect(tab().isDirty, isFalse);
      expect(await File(path('Groceries')).exists(), isFalse);
    });

    test('rich note saved as .txt is written as .rtf, not refused', () async {
      makeRich('Plans');
      picker.next = path('Plans.txt');

      final r = await ops.saveAs(editor, resolvePassword: () async => null);

      expect(r.ok, isTrue, reason: 'error: ${r.error}');
      expect(r.newPath, path('Plans.rtf'));
      expect(await fs.readRtfFile(path('Plans.rtf')), contains('Plans'));
      expect(await File(path('Plans.txt')).exists(), isFalse);
      expect(tab().isDirty, isFalse);
    });

    test('the saved .rtf reopens as the same rich text', () async {
      makeRich('Round trip');
      picker.next = path('Round');
      expect((await ops.saveAs(editor, resolvePassword: () async => null)).ok,
          isTrue);

      final reopened = EditorProvider(fs, settings);
      addTearDown(reopened.dispose);
      await reopened.openRtfFile(path('Round.rtf'),
          RtfService.rtfToDelta(await fs.readRtfFile(path('Round.rtf'))));
      expect(reopened.activeTab!.mode, EditorMode.richText);
      expect(reopened.activeTab!.deltaJson, contains('Round trip'));
      expect(reopened.activeTab!.deltaJson, contains('header'));
    });

    test('plain note with no extension gets .txt', () async {
      tab().controller.text = 'plain words';
      picker.next = path('Plain');

      final r = await ops.saveAs(editor, resolvePassword: () async => null);

      expect(r.ok, isTrue);
      expect(r.newPath, path('Plain.txt'));
      expect(await fs.readTxtFile(path('Plain.txt')), 'plain words');
    });

    test('plain note keeps an extension the user typed', () async {
      tab().controller.text = '# heading';
      picker.next = path('README.md');

      final r = await ops.saveAs(editor, resolvePassword: () async => null);

      expect(r.ok, isTrue);
      expect(r.newPath, path('README.md'));
      expect(r.extensionChanged, isFalse);
      expect(await fs.readTxtFile(path('README.md')), '# heading');
    });

    test('switching tabs while the dialog is open writes nothing', () async {
      makeRich('first note');
      final first = tab();
      editor.addNewTab();
      tab().controller.text = 'second note';
      editor.setActiveTab(0);
      picker.next = path('First');
      picker.whileOpen = () => editor.setActiveTab(1);

      final r = await ops.saveAs(editor, resolvePassword: () async => null);

      expect(r.ok, isFalse);
      expect(r.error, saveTabSwitched);
      expect(await File(path('First.rtf')).exists(), isFalse);
      expect(await File(path('First.txt')).exists(), isFalse);
      expect(first.filePath, isNull);
      expect(editor.tabs[1].filePath, isNull);
    });

    test('a retargeted name already open in another tab is refused', () async {
      await fs.writeRtfFile(path('Shared.rtf'), r'{\rtf1\ansi other\par}');
      await editor.openRtfFile(path('Shared.rtf'), '[{"insert":"other\\n"}]');
      editor.addNewTab();
      makeRich('mine');
      picker.next = path('Shared');

      final r = await ops.saveAs(editor, resolvePassword: () async => null);

      expect(r.ok, isFalse);
      expect(r.error, savePathAlreadyOpen);
      expect(await fs.readRtfFile(path('Shared.rtf')), contains('other'));
    });

    test('a rich note with an image and a bare name still asks before RTF '
        'drops the image', () async {
      editor.toggleEditorMode();
      editor.updateDeltaJson(
          '[{"insert":{"image":"data:image/png;base64,AAAA"}},{"insert":"\\n"}]');
      picker.next = path('Photo');

      var asked = false;
      final r = await ops.saveAs(editor,
          resolvePassword: () async => null,
          confirmLossyRtf: () async {
            asked = true;
            return false;
          });

      expect(asked, isTrue);
      expect(r.ok, isFalse);
      expect(await File(path('Photo.rtf')).exists(), isFalse);
      expect(tab().isDirty, isTrue);
    });

    test('a retargeted name asks before replacing an existing file', () async {
      await fs.writeRtfFile(path('Taken.rtf'), r'{\rtf1\ansi keep me\par}');
      makeRich('new');
      picker.next = path('Taken');

      String? asked;
      final r = await ops.saveAs(editor,
          resolvePassword: () async => null,
          confirmOverwrite: (p) async {
            asked = p;
            return false;
          });

      expect(asked, path('Taken.rtf'));
      expect(r.ok, isFalse);
      expect(r.error, saveOverwriteDeclined);
      expect(await fs.readRtfFile(path('Taken.rtf')), contains('keep me'));
      expect(tab().isDirty, isTrue);
    });
  });

  group('saveActiveTabAs (untitled-tab rename path)', () {
    late Directory tmp;
    late SettingsService settings;
    late EditorProvider editor;
    late FileService fs;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('scrib_saveactiveas_');
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

    String path(String name) => '${tmp.path}$sep$name';

    test('rich text to a .rtf is converted, not written as the JSON envelope',
        () async {
      editor.toggleEditorMode();
      editor.updateDeltaJson('[{"insert":"Named note\\n"}]');

      expect(await editor.saveActiveTabAs(path('Named.rtf')), isTrue);

      final rtf = await fs.readRtfFile(path('Named.rtf'));
      expect(rtf, startsWith(r'{\rtf1'));
      expect(rtf, contains('Named note'));
      expect(rtf, isNot(contains('scrib_rich')));
      expect(editor.activeTab!.isDirty, isFalse);
    });

    test('rich text with an image is refused rather than losing it', () async {
      editor.toggleEditorMode();
      editor.updateDeltaJson(
          '[{"insert":{"image":"data:image/png;base64,AAAA"}},{"insert":"\\n"}]');

      expect(await editor.saveActiveTabAs(path('Pic.rtf')), isFalse);
      expect(await File(path('Pic.rtf')).exists(), isFalse);
      expect(editor.activeTab!.isDirty, isTrue);
    });

    test('plain text is never written into a .rtf', () async {
      editor.activeTab!.controller.text = 'plain';

      expect(await editor.saveActiveTabAs(path('Plain.rtf')), isFalse);
      expect(await File(path('Plain.rtf')).exists(), isFalse);
    });
  });
}
