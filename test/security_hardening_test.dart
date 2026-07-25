import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:scrib_desktop/providers/editor_provider.dart';
import 'package:scrib_desktop/services/file_operations.dart';
import 'package:scrib_desktop/services/file_service.dart';
import 'package:scrib_desktop/services/settings_service.dart';

/// Regression tests for the security review findings fixed after v1.9.0.
void main() {
  late Directory tmp;
  late SettingsService settings;
  late EditorProvider editor;
  late FileService fs;
  late FileOperations ops;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('scrib_sec_');
    settings = SettingsService();
    await settings.initForTests(tmp.path);
    fs = FileService();
    editor = EditorProvider(fs, settings);
    ops = FileOperations(fs, settings);
  });

  tearDown(() async {
    editor.dispose();
    await Hive.close();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  String path(String name) => '${tmp.path}${Platform.pathSeparator}$name';
  EditorTab tab() => editor.activeTab!;

  // Ctrl+E flips isEncrypted without touching filePath. Anything that reasons
  // about the file on disk has to test the path, or the UI ends up reporting a
  // security state the disk does not have.
  group('encryption state is judged by the path, not the intent flag', () {
    test('a tab flagged encrypted over a .txt cannot be locked', () {
      tab().filePath = path('note.txt');
      tab().fileName = 'note.txt';
      tab().isEncrypted = true;
      tab().password = 'pw-abc-123';

      expect(tab().hasScrbPath, isFalse);
      expect(tab().canLock, isFalse,
          reason: 'locking would show a lock screen over a plaintext file '
              'that can never be unlocked');
      expect(editor.hasLockableTabs, isFalse);
    });

    test('a tab over a real .scrb can be locked', () async {
      final p = path('real.scrb');
      await fs.writeScrbFile(p, 'body', 'pw-abc-123', iterations: 1000);
      tab().filePath = p;
      tab().fileName = 'real.scrb';
      tab().isEncrypted = true;
      tab().password = 'pw-abc-123';

      expect(tab().hasScrbPath, isTrue);
      expect(tab().canLock, isTrue);
    });

    test('changeActivePassword refuses a non-.scrb path', () async {
      final p = path('note.txt');
      await File(p).writeAsString('plaintext body');
      tab().filePath = p;
      tab().fileName = 'note.txt';
      tab().isEncrypted = true;
      tab().password = 'old-password';

      expect(await editor.changeActivePassword('new-password'), isFalse);
      expect(await File(p).readAsString(), 'plaintext body',
          reason: 'ciphertext must never be written into a .txt');
      expect(tab().password, 'old-password',
          reason: 'a refused change must not commit the new password');
    });

    test('a failed re-encrypt leaves the OLD password on the tab', () async {
      final p = path('secret.scrb');
      await fs.writeScrbFile(p, 'body', 'old-password', iterations: 1000);
      tab().filePath = p;
      tab().fileName = 'secret.scrb';
      tab().isEncrypted = true;
      tab().password = 'old-password';
      tab().controller.text = 'body';

      // A directory at the staging path makes the atomic write fail.
      await Directory('$p.scrib-tmp').create();

      await expectLater(
          editor.changeActivePassword('new-password'), throwsA(anything));

      expect(tab().password, 'old-password',
          reason: 'the UI reports failure, so the tab must keep the password '
              'the file on disk is actually encrypted under');
      expect(await fs.readScrbFile(p, 'old-password'), 'body');
    });
  });

  // File.delete() unlinks; it does not erase. Encrypting an existing plaintext
  // file has to overwrite the bytes or the "encrypted" note stays readable in
  // free space.
  group('encrypting wipes the plaintext original', () {
    test('the original bytes are overwritten before the file is unlinked',
        () async {
      final txt = path('secret.txt');
      const secret = 'TOPSECRET-CANARY-VALUE-0123456789';
      await File(txt).writeAsString(secret);

      tab().filePath = txt;
      tab().fileName = 'secret.txt';
      tab().controller.text = secret;
      tab().isEncrypted = true;

      final r = await ops.saveActive(
        editor,
        passwordForNewEncryption: 'pw-abc-123',
      );

      expect(r.ok, isTrue);
      expect(await File(txt).exists(), isFalse);
      expect(await fs.readScrbFile(r.newPath!, 'pw-abc-123'), secret);
    });

    test('a stranded .scrib-bak sibling is swept too', () async {
      final txt = path('note.txt');
      await File(txt).writeAsString('body');
      // An interrupted fallback rename leaves a full copy of the old content.
      await File('$txt.scrib-bak').writeAsString('PLAINTEXT-LEFTOVER');

      tab().filePath = txt;
      tab().fileName = 'note.txt';
      tab().controller.text = 'body';
      tab().isEncrypted = true;

      final r = await ops.saveActive(
        editor,
        passwordForNewEncryption: 'pw-abc-123',
      );

      expect(r.ok, isTrue);
      expect(await File('$txt.scrib-bak').exists(), isFalse,
          reason: 'a plaintext backup left beside the encrypted note defeats '
              'the encryption');
    });
  });

  // AtomicWrite replaces the destination outright and leaves no backup, so an
  // edit another program made is unrecoverable once we write over it.
  group('external modification detection', () {
    test('a background save refuses a file changed on disk', () async {
      final p = path('shared.txt');
      await File(p).writeAsString('original');
      await editor.openFile(p);
      final t = editor.activeTab!;
      t.controller.text = 'my edit';

      // Another program rewrites the file, and the mtime moves with it.
      await File(p).writeAsString('THEIR EDIT, MUCH LONGER THAN THE ORIGINAL');

      expect(await editor.saveAllSaveable(), isFalse);
      expect(await File(p).readAsString(),
          'THEIR EDIT, MUCH LONGER THAN THE ORIGINAL',
          reason: 'auto-save silently destroyed another program\'s edit');
      expect(t.isDirty, isTrue, reason: 'a refused save must stay dirty');
    });

    test('the manual save path asks, and overwrites when confirmed', () async {
      final p = path('shared.txt');
      await File(p).writeAsString('original');
      await editor.openFile(p);
      editor.activeTab!.controller.text = 'my edit';

      await File(p).writeAsString('THEIR EDIT, MUCH LONGER THAN THE ORIGINAL');

      final declined = await ops.saveActive(
        editor,
        passwordForNewEncryption: null,
        confirmExternalChange: (_) async => false,
      );
      expect(declined.ok, isFalse);
      expect(declined.error, saveExternalChangeDeclined);
      expect(await File(p).readAsString(),
          'THEIR EDIT, MUCH LONGER THAN THE ORIGINAL');

      var asked = '';
      final accepted = await ops.saveActive(
        editor,
        passwordForNewEncryption: null,
        confirmExternalChange: (q) async {
          asked = q;
          return true;
        },
      );
      expect(accepted.ok, isTrue);
      expect(asked, p);
      expect(await File(p).readAsString(), 'my edit');
    });

    test('an unchanged file is never flagged', () async {
      final p = path('quiet.txt');
      await File(p).writeAsString('original');
      await editor.openFile(p);
      editor.activeTab!.controller.text = 'my edit';

      expect(await editor.diskChangedSince(editor.activeTab!), isFalse);

      var asked = false;
      final r = await ops.saveActive(
        editor,
        passwordForNewEncryption: null,
        confirmExternalChange: (_) async {
          asked = true;
          return true;
        },
      );
      expect(r.ok, isTrue);
      expect(asked, isFalse);
      expect(await File(p).readAsString(), 'my edit');
    });

    test('a save Scrib itself performed does not trip the check', () async {
      final p = path('mine.txt');
      await File(p).writeAsString('original');
      await editor.openFile(p);
      final t = editor.activeTab!;

      t.controller.text = 'first';
      expect(await editor.saveAllSaveable(), isTrue);
      t.controller.text = 'second';
      expect(await editor.saveAllSaveable(), isTrue,
          reason: 'stamping after a write must keep our own saves invisible '
              'to the external-change check');
      expect(await File(p).readAsString(), 'second');
    });
  });

  group('locking clears recoverable in-memory state', () {
    test('the undo stack is cleared so Ctrl+Z cannot rebuild the note',
        () async {
      final p = path('note.scrb');
      await fs.writeScrbFile(p, 'secret body', 'pw-abc-123', iterations: 1000);
      tab().filePath = p;
      tab().fileName = 'note.scrb';
      tab().isEncrypted = true;
      tab().password = 'pw-abc-123';
      tab().controller.text = 'secret body';
      tab().savedContent = 'secret body';

      final t = tab();
      t.undoController.value =
          const UndoHistoryValue(canUndo: true, canRedo: false);

      expect(await editor.lockTab(t), isTrue);
      expect(t.undoController.value.canUndo, isFalse);
      expect(t.controller.text, isEmpty);
      expect(t.password, isNull);
    });
  });

  group('atomic write staging', () {
    test('writes go through the staging file and leave no orphan', () async {
      final p = path('atomic.txt');
      await fs.writeTxtFile(p, 'body');
      expect(await File(p).readAsString(), 'body');
      expect(await File('$p.scrib-tmp').exists(), isFalse);
      expect(await File('$p.scrib-bak').exists(), isFalse);
    });

    test('a .scrb round-trips after an overwrite of an existing file',
        () async {
      final p = path('round.scrb');
      await fs.writeScrbFile(p, 'first', 'pw-abc-123', iterations: 1000);
      await fs.writeScrbFile(p, 'second', 'pw-abc-123', iterations: 1000);
      expect(await fs.readScrbFile(p, 'pw-abc-123'), 'second');
      final bytes = await File(p).readAsBytes();
      expect(bytes.sublist(0, 4), equals(Uint8List.fromList('SCRB'.codeUnits)));
    });
  });

  group('save routing refuses mismatched containers', () {
    test('saveActiveTabAs refuses ciphertext into a .txt', () async {
      final p = path('note.txt');
      tab().controller.text = 'body';
      expect(
        await editor.saveActiveTabAs(p, encrypted: true, password: 'pw-abc-123'),
        isFalse,
      );
      expect(await File(p).exists(), isFalse);
    });

    test('saveActiveTabAs refuses plaintext into a .scrb', () async {
      final p = path('note.scrb');
      tab().controller.text = 'body';
      expect(await editor.saveActiveTabAs(p), isFalse);
      expect(await File(p).exists(), isFalse);
    });

    test('saveActiveTabAs refuses a rich Delta into a .txt', () async {
      final p = path('rich.txt');
      tab().mode = EditorMode.richText;
      tab().deltaJson = '[{"insert":"hello\n"}]';
      expect(await editor.saveActiveTabAs(p), isFalse,
          reason: 'the scrib_rich envelope would show as JSON elsewhere');
      expect(await File(p).exists(), isFalse);
    });
  });

  group('two tabs never share one file', () {
    test('saveAs refuses a path another tab already holds', () async {
      final taken = path('taken.txt');
      await File(taken).writeAsString('first tab');
      await editor.openFile(taken);

      editor.addNewTab();
      final second = editor.tabs.last;
      editor.setActiveTab(editor.tabs.indexOf(second));
      second.controller.text = 'second tab';

      expect(editor.isPathOpenInOtherTab(taken, second), isTrue);
      expect(editor.isPathOpenInOtherTab(path('free.txt'), second), isFalse);
      expect(await File(taken).readAsString(), 'first tab');
    });
  });
}
