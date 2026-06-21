import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:scrib_desktop/providers/editor_provider.dart';
import 'package:scrib_desktop/services/file_operations.dart';
import 'package:scrib_desktop/services/file_service.dart';
import 'package:scrib_desktop/services/settings_service.dart';

/// Drives FileOperations.saveActive through its A–D decision branches with a
/// real FileService writing to a temp dir. This logic decides .scrb<->.txt/.rtf
/// renames on encryption toggle and routes RTF vs plain writes — a regression
/// here corrupts files or silently drops encryption.
void main() {
  late Directory tmp;
  late SettingsService settings;
  late EditorProvider editor;
  late FileService fs;
  late FileOperations ops;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('scrib_fileops_');
    settings = SettingsService();
    await settings.initForTests(tmp.path);
    fs = FileService();
    editor = EditorProvider(fs, settings);
    ops = FileOperations(fs, settings);
  });

  tearDown(() async {
    editor.dispose();
    await Hive.close();
    try { await tmp.delete(recursive: true); } catch (_) {}
  });

  String path(String name) => '${tmp.path}${Platform.pathSeparator}$name';
  EditorTab tab() => editor.activeTab!;

  test('returns "Needs save-as" when the active tab has no filePath', () async {
    expect(tab().filePath, isNull);
    final r = await ops.saveActive(editor, passwordForNewEncryption: null);
    expect(r.ok, isFalse);
    expect(r.error, 'Needs save-as');
  });

  test('Case A: plain .txt toggled encrypted renames to .scrb and encrypts', () async {
    tab().filePath = path('note.txt');
    tab().controller.text = 'top secret';
    tab().isEncrypted = true;
    final r = await ops.saveActive(editor, passwordForNewEncryption: 'pw-abc-123');
    expect(r.ok, isTrue);
    expect(r.extensionChanged, isTrue);
    expect(r.newPath, endsWith('.scrb'));
    expect(await File(r.newPath!).exists(), isTrue);
    expect(await fs.readScrbFile(r.newPath!, 'pw-abc-123'), 'top secret');
  });

  test('Case A: encrypted toggle with no password anywhere fails', () async {
    tab().filePath = path('note.txt');
    tab().controller.text = 'x';
    tab().isEncrypted = true;
    tab().password = null;
    final r = await ops.saveActive(editor, passwordForNewEncryption: null);
    expect(r.ok, isFalse);
    expect(r.error, 'Password required');
  });

  test('Case B: encrypted .scrb toggled to plain (plain mode) writes .txt unencrypted', () async {
    // Seed a real .scrb on disk, then flip the tab to plaintext.
    final scrbPath = path('secret.scrb');
    await fs.writeScrbFile(scrbPath, 'was encrypted', 'pw', iterations: 1000);
    tab().filePath = scrbPath;
    tab().controller.text = 'was encrypted';
    tab().isEncrypted = false;
    tab().password = null;
    final r = await ops.saveActive(editor, passwordForNewEncryption: null);
    expect(r.ok, isTrue);
    expect(r.extensionChanged, isTrue);
    expect(r.newPath, endsWith('.txt'));
    expect(await fs.readTxtFile(r.newPath!), 'was encrypted');
    expect(await fs.isScrbFile(r.newPath!), isFalse);
  });

  test('Case B: encrypted .scrb toggled to plain (rich mode) writes parseable .rtf', () async {
    final scrbPath = path('rich.scrb');
    await fs.writeScrbFile(scrbPath, 'x', 'pw', iterations: 1000);
    tab().filePath = scrbPath;
    tab().isEncrypted = false;
    tab().password = null;
    tab().mode = EditorMode.richText;
    tab().deltaJson = '[{"insert":"hello rtf\\n"}]';
    final r = await ops.saveActive(editor, passwordForNewEncryption: null);
    expect(r.ok, isTrue);
    expect(r.newPath, endsWith('.rtf'));
    final rtf = await fs.readRtfFile(r.newPath!);
    expect(rtf, startsWith(r'{\rtf1'));
    expect(rtf, contains('hello rtf'));
  });

  test('Case C: encrypted same-path save with no password available fails', () async {
    final scrbPath = path('keep.scrb');
    await fs.writeScrbFile(scrbPath, 'x', 'pw', iterations: 1000);
    tab().filePath = scrbPath;
    tab().isEncrypted = true;
    tab().password = null;
    final r = await ops.saveActive(editor, passwordForNewEncryption: null);
    expect(r.ok, isFalse);
    expect(r.error, 'Password required');
  });

  test('Case D: in-place .txt save writes plain content with no extension change', () async {
    final txtPath = path('plain.txt');
    await fs.writeTxtFile(txtPath, 'old');
    tab().filePath = txtPath;
    tab().controller.text = 'new content';
    tab().isEncrypted = false;
    final r = await ops.saveActive(editor, passwordForNewEncryption: null);
    expect(r.ok, isTrue);
    expect(r.extensionChanged, isFalse);
    expect(await fs.readTxtFile(txtPath), 'new content');
  });

  test('Case D: in-place .rtf save converts Delta to RTF', () async {
    final rtfPath = path('doc.rtf');
    await fs.writeRtfFile(rtfPath, r'{\rtf1\ansi\deff0 old\par}');
    tab().filePath = rtfPath;
    tab().isEncrypted = false;
    tab().mode = EditorMode.richText;
    tab().deltaJson = '[{"insert":"converted body\\n"}]';
    final r = await ops.saveActive(editor, passwordForNewEncryption: null);
    expect(r.ok, isTrue);
    expect(r.extensionChanged, isFalse);
    final rtf = await fs.readRtfFile(rtfPath);
    expect(rtf, contains('converted body'));
    expect(rtf, isNot(contains('scrib_rich')));
  });

  test('Case A: in-place encrypted save round-trips with an existing password', () async {
    final scrbPath = path('enc.scrb');
    await fs.writeScrbFile(scrbPath, 'v1', 'mypw', iterations: 1000);
    tab().filePath = scrbPath;
    tab().controller.text = 'v2 content';
    tab().isEncrypted = true;
    tab().password = 'mypw';
    final r = await ops.saveActive(editor, passwordForNewEncryption: null);
    expect(r.ok, isTrue);
    expect(await fs.readScrbFile(scrbPath, 'mypw'), 'v2 content');
  });

  test('a write failure is caught and returned as a failure result', () async {
    // Point at a path whose parent directory does not exist.
    tab().filePath = '${tmp.path}${Platform.pathSeparator}no_such_dir'
        '${Platform.pathSeparator}x.txt';
    tab().controller.text = 'data';
    tab().isEncrypted = false;
    final r = await ops.saveActive(editor, passwordForNewEncryption: null);
    expect(r.ok, isFalse);
    expect(r.error, isNotNull);
  });

  test('encryption-toggle rename preserves the directory and base name', () async {
    tab().filePath = path('my.note.txt'); // multi-dot name
    tab().controller.text = 'multi dot';
    tab().isEncrypted = true;
    final r = await ops.saveActive(editor, passwordForNewEncryption: 'pw-xyz');
    expect(r.ok, isTrue);
    expect(r.newPath, path('my.note.scrb'));
  });
}
