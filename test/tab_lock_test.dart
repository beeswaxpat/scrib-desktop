import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:scrib_desktop/providers/editor_provider.dart';
import 'package:scrib_desktop/services/file_service.dart';
import 'package:scrib_desktop/services/settings_service.dart';

/// Locked-tab behavior: locking wipes secrets from tab state, a locked tab can
/// never be written to disk, and unlocking restores content through the normal
/// decrypt path.
void main() {
  late Directory tmp;
  late SettingsService settings;
  late EditorProvider editor;
  late FileService fs;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('scrib_lock_');
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

  Future<String> writeScrb(String name, String content, String pw) async {
    final p = '${tmp.path}${Platform.pathSeparator}$name';
    await fs.writeScrbFile(p, content, pw, iterations: 1000);
    return p;
  }

  group('addLockedTab', () {
    test('creates a locked placeholder with no content or password', () async {
      final p = await writeScrb('a.scrb', 'secret', 'pw');
      final tab = editor.addLockedTab(p);
      expect(tab.isLocked, isTrue);
      expect(tab.isEncrypted, isTrue);
      expect(tab.password, isNull);
      expect(tab.controller.text, isEmpty);
      expect(tab.isDirty, isFalse);
    });

    test('replaces a single empty untitled tab', () async {
      final p = await writeScrb('a.scrb', 'secret', 'pw');
      expect(editor.tabs.length, 1);
      editor.addLockedTab(p);
      expect(editor.tabs.length, 1);
      expect(editor.activeTab!.isLocked, isTrue);
    });

    test('activates the existing tab when the file is already open', () async {
      final p = await writeScrb('a.scrb', 'secret', 'pw');
      final first = editor.addLockedTab(p);
      editor.addNewTab();
      final second = editor.addLockedTab(p);
      expect(identical(first, second), isTrue);
      expect(editor.activeTab, same(first));
    });
  });

  group('unlock via openScrbFile', () {
    test('fills the locked placeholder in place and clears isLocked', () async {
      final p = await writeScrb('a.scrb', 'secret content', 'pw');
      final placeholder = editor.addLockedTab(p);

      final ok = await editor.openScrbFile(p, 'pw');
      expect(ok, isTrue);
      expect(editor.tabs.length, 1);
      expect(editor.activeTab, same(placeholder));
      expect(placeholder.isLocked, isFalse);
      expect(placeholder.controller.text, 'secret content');
      expect(placeholder.password, 'pw');
    });

    test('wrong password leaves the tab locked', () async {
      final p = await writeScrb('a.scrb', 'secret', 'pw');
      final placeholder = editor.addLockedTab(p);

      final ok = await editor.openScrbFile(p, 'wrong');
      expect(ok, isFalse);
      expect(placeholder.isLocked, isTrue);
      expect(placeholder.controller.text, isEmpty);
    });
  });

  group('lockTab', () {
    test('wipes content, password, and snapshot state', () async {
      final p = await writeScrb('a.scrb', 'secret', 'pw');
      await editor.openScrbFile(p, 'pw');
      final tab = editor.activeTab!;

      final locked = await editor.lockTab(tab);
      expect(locked, isTrue);
      expect(tab.isLocked, isTrue);
      expect(tab.password, isNull);
      expect(tab.controller.text, isEmpty);
      expect(tab.deltaJson, isEmpty);
      expect(tab.savedDeltaJson, isEmpty);
      expect(tab.isDirty, isFalse);
    });

    test('saves unsaved changes before locking', () async {
      final p = await writeScrb('a.scrb', 'original', 'pw');
      await editor.openScrbFile(p, 'pw');
      final tab = editor.activeTab!;
      tab.controller.text = 'edited secret';
      expect(tab.isDirty, isTrue);

      final locked = await editor.lockTab(tab);
      expect(locked, isTrue);
      expect(tab.isLocked, isTrue);

      final onDisk = await fs.readScrbFile(p, 'pw');
      expect(onDisk, 'edited secret');
    });

    test('refuses an encrypted tab that has never been saved', () async {
      editor.addNewTab();
      final tab = editor.activeTab!;
      tab.controller.text = 'unsaved';
      editor.toggleEncryption();
      expect(tab.isEncrypted, isTrue);
      expect(tab.filePath, isNull);

      expect(await editor.lockTab(tab), isFalse);
      expect(tab.isLocked, isFalse);
      expect(tab.controller.text, 'unsaved');
    });

    test('refuses a plain-text tab', () async {
      final p = '${tmp.path}${Platform.pathSeparator}plain.txt';
      await File(p).writeAsString('hello');
      await editor.openFile(p);
      expect(await editor.lockTab(editor.activeTab!), isFalse);
    });
  });

  group('locked tabs are never written', () {
    test('saveActiveTab refuses and leaves the encrypted file intact', () async {
      final p = await writeScrb('a.scrb', 'secret', 'pw');
      editor.addLockedTab(p);
      final before = await File(p).readAsBytes();

      expect(await editor.saveActiveTab(), isFalse);
      expect(await editor.saveActiveTabAs('${tmp.path}\\other.txt'), isFalse);

      final after = await File(p).readAsBytes();
      expect(after, before);
      expect(await fs.readScrbFile(p, 'pw'), 'secret');
    });

    test('auto-save / save-all skips locked tabs', () async {
      final p = await writeScrb('a.scrb', 'secret', 'pw');
      editor.addLockedTab(p);
      final before = await File(p).readAsBytes();

      final allSaved = await editor.saveAllSaveable();
      expect(allSaved, isTrue); // locked tab is not dirty, nothing pending
      expect(await File(p).readAsBytes(), before);
    });

    test('mode and encryption toggles are no-ops while locked', () async {
      final p = await writeScrb('a.scrb', 'secret', 'pw');
      final tab = editor.addLockedTab(p);

      editor.toggleEncryption();
      expect(tab.isEncrypted, isTrue);

      editor.toggleEditorMode();
      expect(tab.mode, EditorMode.plainText);

      editor.updateDeltaJson('[{"insert":"x\\n"}]');
      expect(tab.deltaJson, isEmpty);
    });
  });

  group('lockAllEncrypted', () {
    test('locks only lockable tabs and reports the count', () async {
      final scrb = await writeScrb('a.scrb', 'secret', 'pw');
      await editor.openScrbFile(scrb, 'pw');

      final txt = '${tmp.path}${Platform.pathSeparator}b.txt';
      await File(txt).writeAsString('plain');
      await editor.openFile(txt);

      editor.addNewTab(); // untitled

      expect(editor.hasLockableTabs, isTrue);
      final locked = await editor.lockAllEncrypted();
      expect(locked, 1);
      expect(editor.hasLockableTabs, isFalse);
      expect(editor.tabs.where((t) => t.isLocked).length, 1);
    });
  });

  group('canLock', () {
    test('true only for saved encrypted tabs with a usable state', () async {
      final p = await writeScrb('a.scrb', 'secret', 'pw');
      await editor.openScrbFile(p, 'pw');
      expect(editor.activeTab!.canLock, isTrue);

      editor.addNewTab();
      expect(editor.activeTab!.canLock, isFalse);
    });
  });

  group('locked-tab mutator guards', () {
    test('markTabSavedAs is a no-op on a locked tab', () async {
      final p = await writeScrb('a.scrb', 'secret', 'pw');
      final tab = editor.addLockedTab(p);

      editor.markTabSavedAs('${tmp.path}${Platform.pathSeparator}else.txt');

      expect(tab.filePath, p,
          reason: 'a locked tab must never be re-pointed at a new path');
      expect(tab.isEncrypted, isTrue,
          reason: 'a locked tab must never be downgraded to unencrypted');
      expect(tab.isLocked, isTrue);
      expect(tab.password, isNull);
    });
  });

  group('pre-lock save failure', () {
    test('lockTab on a dirty tab whose save fails does not wipe content and '
        'reports failure instead of throwing', () async {
      final p = await writeScrb('a.scrb', 'original', 'pw');
      await editor.openScrbFile(p, 'pw');
      final tab = editor.activeTab!;
      tab.controller.text = 'unsaved secret edit';
      expect(tab.isDirty, isTrue);

      // Point the tab at a path whose directory does not exist so the
      // pre-lock save throws inside the file service.
      tab.filePath = '${tmp.path}${Platform.pathSeparator}no_such_dir'
          '${Platform.pathSeparator}gone.scrb';

      final locked = await editor.lockTab(tab); // must complete, not throw
      expect(locked, isFalse);
      expect(tab.isLocked, isFalse);
      expect(tab.controller.text, 'unsaved secret edit',
          reason: 'a failed persist must never wipe the unsaved edits');
      expect(tab.password, isNotNull,
          reason: 'the password must survive so the user can still save');
    });

    test('lockAllEncrypted survives one failing tab and still locks the others', () async {
      final good = await writeScrb('good.scrb', 'good secret', 'pw');
      await editor.openScrbFile(good, 'pw');
      final goodTab = editor.activeTab!;
      goodTab.controller.text = 'good edited';

      final bad = await writeScrb('bad.scrb', 'bad secret', 'pw');
      await editor.openScrbFile(bad, 'pw');
      final badTab = editor.activeTab!;
      badTab.controller.text = 'bad edited';
      badTab.filePath = '${tmp.path}${Platform.pathSeparator}no_such_dir'
          '${Platform.pathSeparator}bad.scrb';

      // The idle auto-lock timer calls this unawaited — it must not throw.
      final locked = await editor.lockAllEncrypted();
      expect(locked, 1);
      expect(goodTab.isLocked, isTrue);
      expect(badTab.isLocked, isFalse);
      expect(badTab.controller.text, 'bad edited');
      expect(await fs.readScrbFile(good, 'pw'), 'good edited');
    });
  });

  group('changeActivePassword', () {
    test('re-encrypts the file with the new password', () async {
      final p = await writeScrb('a.scrb', 'secret', 'old-pw');
      await editor.openScrbFile(p, 'old-pw');

      final changed = await editor.changeActivePassword('new-pw');
      expect(changed, isTrue);

      expect(await fs.readScrbFile(p, 'old-pw'), isNull);
      expect(await fs.readScrbFile(p, 'new-pw'), 'secret');
    });

    test('refuses locked and unencrypted tabs', () async {
      final p = await writeScrb('a.scrb', 'secret', 'pw');
      editor.addLockedTab(p);
      expect(await editor.changeActivePassword('x'), isFalse);

      editor.addNewTab();
      expect(await editor.changeActivePassword('x'), isFalse);
    });
  });
}
