import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:scrib_desktop/constants.dart';
import 'package:scrib_desktop/providers/editor_provider.dart';
import 'package:scrib_desktop/services/file_operations.dart';
import 'package:scrib_desktop/services/file_service.dart';
import 'package:scrib_desktop/services/settings_service.dart';

/// A FileService that runs [onWrite] in the middle of every write, after the
/// caller has snapshotted the content it intends to persist but before the
/// bytes land. That is exactly the window a user types into during a real
/// save: an encrypted write is an isolate spawn plus 100k PBKDF2 rounds plus
/// two forced flushes, well over 100ms, and it repeats on every auto-save.
class _MidWriteHookFileService extends FileService {
  void Function()? onWrite;

  void _fire() {
    final hook = onWrite;
    onWrite = null; // one-shot: the follow-up save must not re-trigger it
    hook?.call();
  }

  @override
  Future<void> writeTxtFile(String path, String content) async {
    _fire();
    await super.writeTxtFile(path, content);
  }

  @override
  Future<void> writeRtfFile(String path, String content) async {
    _fire();
    await super.writeRtfFile(path, content);
  }

  @override
  Future<void> writeScrbFile(
    String path,
    String content,
    String password, {
    int iterations = scrbV3DefaultIterations,
  }) async {
    _fire();
    await super.writeScrbFile(path, content, password, iterations: iterations);
  }
}

void main() {
  late Directory tmp;
  late SettingsService settings;
  late EditorProvider editor;
  late _MidWriteHookFileService fs;
  late FileOperations ops;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('scrib_save_race_');
    settings = SettingsService();
    await settings.initForTests(tmp.path);
    fs = _MidWriteHookFileService();
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

  // ── Edits made DURING a save must survive ────────────────────────────────
  //
  // markSaved() used to take no argument and re-read the tab's LIVE content,
  // so anything typed while the write was in flight was recorded as "saved"
  // even though only the older bytes reached disk. The tab then went clean,
  // the quit backstop saw nothing pending, and the text was gone.
  group('save completion records the bytes written, not the live content', () {
    test('plain text typed during a save leaves the tab dirty', () async {
      final p = path('note.txt');
      tab().filePath = p;
      tab().fileName = 'note.txt';
      tab().controller.text = 'version one';

      fs.onWrite = () => tab().controller.text = 'version one plus more';

      expect(await editor.saveActiveTab(), isTrue);

      // Only the snapshot reached disk...
      expect(await File(p).readAsString(), 'version one');
      // ...so the tab must still be dirty and save again later.
      expect(tab().isDirty, isTrue,
          reason: 'text typed during the write was marked saved but never written');

      expect(await editor.saveActiveTab(), isTrue);
      expect(await File(p).readAsString(), 'version one plus more');
      expect(tab().isDirty, isFalse);
    });

    // A rich tab over a .txt is refused outright (the scrib_rich envelope
    // would corrupt it), so the rich race is exercised on the two paths that
    // legitimately accept rich content: .rtf and .scrb.
    test('rich text edited during an RTF save leaves the tab dirty', () async {
      final p = path('note.rtf');
      tab().filePath = p;
      tab().fileName = 'note.rtf';
      tab().mode = EditorMode.richText;
      tab().deltaJson = '[{"insert":"one\\n"}]';

      fs.onWrite = () => tab().deltaJson = '[{"insert":"one two\\n"}]';

      expect(await editor.saveActiveTab(), isTrue);

      final onDisk = await File(p).readAsString();
      expect(onDisk, contains('one'));
      expect(onDisk, isNot(contains('one two')),
          reason: 'the mid-write edit must not have reached disk');
      expect(tab().isDirty, isTrue);
    });

    test('rich text edited during an encrypted save leaves the tab dirty',
        () async {
      final p = path('note.scrb');
      tab().filePath = p;
      tab().fileName = 'note.scrb';
      tab().isEncrypted = true;
      tab().password = 'pw-abc-123';
      tab().mode = EditorMode.richText;
      tab().deltaJson = '[{"insert":"one\\n"}]';

      fs.onWrite = () => tab().deltaJson = '[{"insert":"one two\\n"}]';

      expect(await editor.saveActiveTab(), isTrue);

      expect(await fs.readScrbFile(p, 'pw-abc-123'),
          '{"scrib_rich":[{"insert":"one\\n"}]}');
      expect(tab().isDirty, isTrue);
    });

    test('encrypted content typed during a save leaves the tab dirty', () async {
      final p = path('secret.scrb');
      tab().filePath = p;
      tab().fileName = 'secret.scrb';
      tab().isEncrypted = true;
      tab().password = 'pw-abc-123';
      tab().controller.text = 'secret one';

      fs.onWrite = () => tab().controller.text = 'secret one plus more';

      expect(await editor.saveActiveTab(), isTrue);

      expect(await fs.readScrbFile(p, 'pw-abc-123'), 'secret one');
      expect(tab().isDirty, isTrue);
    });

    test('auto-save loop leaves a tab edited mid-write dirty', () async {
      final p = path('auto.txt');
      tab().filePath = p;
      tab().fileName = 'auto.txt';
      tab().controller.text = 'auto one';

      fs.onWrite = () => tab().controller.text = 'auto one plus more';

      expect(await editor.saveAllSaveable(), isFalse,
          reason: 'the tab was edited during the write, so changes remain');
      expect(await File(p).readAsString(), 'auto one');
      expect(tab().isDirty, isTrue);
    });

    // A save in flight races the idle auto-lock: lockTab can wipe the tab
    // while _saveTabToDisk is still awaiting its write. The snapshot handed to
    // markSaved holds the DECRYPTED note, so writing it back into a tab that
    // has since locked would both re-seed plaintext into a locked tab and pin
    // it permanently dirty (locked tabs are refused by every save path, so the
    // quit backstop could never clean it again).
    test('a lock landing mid-write is not undone by the completing save',
        () async {
      final p = path('locked.scrb');
      tab().filePath = p;
      tab().fileName = 'locked.scrb';
      tab().isEncrypted = true;
      tab().password = 'pw-abc-123';
      tab().controller.text = 'the decrypted secret';

      final locked = tab();
      fs.onWrite = () => locked.lock();

      await editor.saveActiveTab();

      expect(locked.isLocked, isTrue);
      expect(locked.savedContent, isEmpty,
          reason: 'the completing save re-seeded plaintext into a locked tab');
      expect(locked.deltaJson, isEmpty);
      expect(locked.savedDeltaJson, isEmpty);
      expect(locked.password, isNull);
      expect(locked.isDirty, isFalse,
          reason: 'a locked tab pinned dirty can never be saved or quit past');
      expect(editor.hasUnsavedChanges, isFalse);
    });

    // The manual save path awaits dialogs and the write itself; the user can
    // switch tabs during those awaits. The completion must land on the tab
    // that was saved, not on whatever is active when the write returns.
    test('switching tabs mid-write does not mark the wrong tab saved',
        () async {
      final p = path('first.rtf');
      final first = tab();
      first.filePath = p;
      first.fileName = 'first.rtf';
      first.mode = EditorMode.richText;
      first.deltaJson = '[{"insert":"first note\\n"}]';

      editor.addNewTab();
      final second = editor.tabs.last;
      second.controller.text = 'second note';
      editor.setActiveTab(editor.tabs.indexOf(first));

      // The user switches to the other tab while the RTF write is in flight.
      fs.onWrite = () => editor.setActiveTab(editor.tabs.indexOf(second));

      final r = await ops.saveActive(editor, passwordForNewEncryption: null);
      expect(r.ok, isTrue);

      expect(first.filePath, p);
      expect(second.filePath, isNull,
          reason: 'the other tab was retargeted at the written path');
      expect(second.savedContent, isNot(contains('first note')),
          reason: "one tab's content was recorded against another tab");
      expect(second.controller.text, 'second note');
    });

    test('a save that writes nothing new still clears the dirty flag', () async {
      final p = path('quiet.txt');
      tab().filePath = p;
      tab().fileName = 'quiet.txt';
      tab().controller.text = 'untouched';

      expect(await editor.saveActiveTab(), isTrue);
      expect(await File(p).readAsString(), 'untouched');
      expect(tab().isDirty, isFalse);
    });
  });

  // ── Extension swaps must not silently destroy an existing file ───────────
  //
  // The swap branches computed a destination and wrote it through
  // AtomicWrite, which uses MOVEFILE_REPLACE_EXISTING — so the pre-existing
  // file at the destination was replaced with no backup, and the source was
  // then deleted. Two files gone from one Ctrl+S.
  group('extension swap refuses to clobber an existing file', () {
    test('Case A (.txt to .scrb) fails and preserves both files when declined',
        () async {
      final txt = path('note.txt');
      final scrb = path('note.scrb');
      await File(txt).writeAsString('plaintext body');
      await fs.writeScrbFile(scrb, 'a DIFFERENT encrypted note', 'other-pw',
          iterations: 1000);
      final before = await File(scrb).readAsBytes();

      tab().filePath = txt;
      tab().controller.text = 'plaintext body';
      tab().isEncrypted = true;

      final r = await ops.saveActive(
        editor,
        passwordForNewEncryption: 'pw-abc-123',
        confirmOverwrite: (_) async => false,
      );

      expect(r.ok, isFalse);
      expect(r.error, saveOverwriteDeclined);
      expect(await File(scrb).readAsBytes(), before,
          reason: 'the existing .scrb was replaced without asking');
      expect(await File(txt).exists(), isTrue,
          reason: 'the source file was deleted after a refused save');
    });

    test('Case A proceeds when the overwrite is confirmed', () async {
      final txt = path('note.txt');
      final scrb = path('note.scrb');
      await File(txt).writeAsString('plaintext body');
      await fs.writeScrbFile(scrb, 'old', 'other-pw', iterations: 1000);

      tab().filePath = txt;
      tab().controller.text = 'plaintext body';
      tab().isEncrypted = true;

      var asked = '';
      final r = await ops.saveActive(
        editor,
        passwordForNewEncryption: 'pw-abc-123',
        confirmOverwrite: (p) async {
          asked = p;
          return true;
        },
      );

      expect(r.ok, isTrue);
      expect(asked, scrb);
      expect(await fs.readScrbFile(scrb, 'pw-abc-123'), 'plaintext body');
      expect(await File(txt).exists(), isFalse);
    });

    test('Case A with no confirmation callback refuses rather than clobbering',
        () async {
      final txt = path('note.txt');
      final scrb = path('note.scrb');
      await File(txt).writeAsString('body');
      await fs.writeScrbFile(scrb, 'keep me', 'other-pw', iterations: 1000);

      tab().filePath = txt;
      tab().controller.text = 'body';
      tab().isEncrypted = true;

      final r = await ops.saveActive(editor, passwordForNewEncryption: 'pw-abc-123');

      expect(r.ok, isFalse);
      expect(await fs.readScrbFile(scrb, 'other-pw'), 'keep me');
    });

    test('Case B (.scrb to .txt) fails and preserves both files when declined',
        () async {
      final scrb = path('secret.scrb');
      final txt = path('secret.txt');
      await fs.writeScrbFile(scrb, 'encrypted body', 'pw', iterations: 1000);
      await File(txt).writeAsString('an UNRELATED existing note');

      tab().filePath = scrb;
      tab().controller.text = 'encrypted body';
      tab().isEncrypted = false;
      tab().password = null;

      final r = await ops.saveActive(
        editor,
        passwordForNewEncryption: null,
        confirmOverwrite: (_) async => false,
      );

      expect(r.ok, isFalse);
      expect(r.error, saveOverwriteDeclined);
      expect(await File(txt).readAsString(), 'an UNRELATED existing note');
      expect(await File(scrb).exists(), isTrue);
    });

    test('Case B2 (.txt to .rtf on mode swap) refuses when the .rtf exists',
        () async {
      final txt = path('doc.txt');
      final rtf = path('doc.rtf');
      await File(txt).writeAsString('plain');
      await File(rtf).writeAsString(r'{\rtf1 existing document}');

      tab().filePath = txt;
      tab().isEncrypted = false;
      tab().mode = EditorMode.richText;
      tab().deltaJson = '[{"insert":"rich now\\n"}]';

      final r = await ops.saveActive(
        editor,
        passwordForNewEncryption: null,
        confirmOverwrite: (_) async => false,
      );

      expect(r.ok, isFalse);
      expect(r.error, saveOverwriteDeclined);
      expect(await File(rtf).readAsString(), r'{\rtf1 existing document}');
      expect(await File(txt).exists(), isTrue);
    });

    test('a swap onto a path that does not exist never asks', () async {
      final txt = path('fresh.txt');
      await File(txt).writeAsString('body');

      tab().filePath = txt;
      tab().controller.text = 'body';
      tab().isEncrypted = true;

      var asked = false;
      final r = await ops.saveActive(
        editor,
        passwordForNewEncryption: 'pw-abc-123',
        confirmOverwrite: (_) async {
          asked = true;
          return true;
        },
      );

      expect(r.ok, isTrue);
      expect(asked, isFalse, reason: 'nothing was at the destination to replace');
    });

    test('an in-place save is never treated as an overwrite', () async {
      final p = path('inplace.txt');
      await File(p).writeAsString('old');

      tab().filePath = p;
      tab().controller.text = 'new';

      var asked = false;
      final r = await ops.saveActive(
        editor,
        passwordForNewEncryption: null,
        confirmOverwrite: (_) async {
          asked = true;
          return true;
        },
      );

      expect(r.ok, isTrue);
      expect(asked, isFalse);
      expect(await File(p).readAsString(), 'new');
    });
  });
}
