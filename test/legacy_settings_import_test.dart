import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:scrib_desktop/services/settings_service.dart';

/// 1.10.0 moved the settings folder (Runner.rc company/product rename), so
/// upgraders started from defaults. SettingsService imports the old box once,
/// without touching the old file.
void main() {
  late Directory tmp;
  late String oldDir;
  late String newDir;
  late String oldFile;
  final sep = Platform.pathSeparator;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('scrib_legacy_');
    oldDir = '${tmp.path}${sep}old';
    newDir = '${tmp.path}${sep}new';
    await Directory(oldDir).create();
    await Directory(newDir).create();
    oldFile = '$oldDir${sep}scrib_desktop_settings.hive';
  });

  tearDown(() async {
    await Hive.close();
    try { await tmp.delete(recursive: true); } catch (_) {}
  });

  /// Write a box the way Scrib 1.9 did, in its own folder, then close it.
  Future<void> seedOldBox(Map<String, dynamic> values) async {
    Hive.init(oldDir);
    final box = await Hive.openBox('scrib_desktop_settings');
    await box.putAll(values);
    await box.close();
  }

  Future<SettingsService> openNew() async {
    final s = SettingsService();
    await s.initForTests(newDir);
    return s;
  }

  final oldValues = <String, dynamic>{
    'themeMode': 1,
    'fontFamily': 'Consolas',
    'fontSize': 18.0,
    'autoSaveInterval': 0,
    'autoLockMinutes': 5,
    'recentFiles': ['C:\\notes\\a.txt', 'C:\\notes\\b.rtf'],
    'defaultSaveLocation': 'D:\\MyNotes',
    'sessionJson': '{"tabs":[{"path":"C:\\\\notes\\\\a.txt"}],"active":0}',
  };

  test('an unused box takes every old setting', () async {
    await seedOldBox(oldValues);
    final s = await openNew();

    await s.importLegacySettings(oldFile);

    expect(s.themeMode, 1);
    expect(s.fontFamily, 'Consolas');
    expect(s.fontSize, 18.0);
    expect(s.autoSaveInterval, 0);
    expect(s.autoLockMinutes, 5);
    expect(s.recentFiles, ['C:\\notes\\a.txt', 'C:\\notes\\b.rtf']);
    expect(s.defaultSaveLocation, 'D:\\MyNotes');
    expect(s.sessionTabs, [
      {'path': 'C:\\notes\\a.txt'}
    ]);
  });

  test('the old file is left byte for byte as it was', () async {
    await seedOldBox(oldValues);
    final before = await File(oldFile).readAsBytes();
    final s = await openNew();

    await s.importLegacySettings(oldFile);

    expect(await File(oldFile).readAsBytes(), before);
    expect(await File('$oldDir${sep}scrib_desktop_settings.lock').exists(),
        isFalse,
        reason: 'the old box must not be opened, so Hive never locks it');
  });

  test('a box already in use only gains the preferences it is missing',
      () async {
    await seedOldBox(oldValues);
    final s = await openNew();
    await s.setThemeMode(2); // chosen in 1.10.0, must win
    await s.setDefaultSaveLocation('C:\\Users\\me\\Desktop\\Scrib');
    await s.setRestoreSession(false); // switched off in 1.10.0

    await s.importLegacySettings(oldFile);

    expect(s.themeMode, 2);
    expect(s.fontFamily, 'Consolas');
    expect(s.fontSize, 18.0);
    expect(s.autoLockMinutes, 5);
    expect(s.recentFiles, ['C:\\notes\\a.txt', 'C:\\notes\\b.rtf']);
    expect(s.defaultSaveLocation, 'C:\\Users\\me\\Desktop\\Scrib');
    expect(s.restoreSession, isFalse);
    expect(s.sessionTabs, isEmpty,
        reason: 'an old session must not come back into a box in use');
    expect(s.autoSaveInterval, 30,
        reason: 'an old "off" must not quietly stop auto-save');
  });

  test('runs once: later changes to the old file are ignored', () async {
    await seedOldBox(oldValues);
    final s = await openNew();
    await s.importLegacySettings(oldFile);
    await s.setFontSize(12.0);

    await Hive.close();
    await seedOldBox({'fontSize': 30.0, 'accentColorIndex': 3});
    final again = await openNew();
    await again.importLegacySettings(oldFile);

    expect(again.fontSize, 12.0);
    expect(again.accentColorIndex, 0);
  });

  test('no old file is a no-op', () async {
    final s = await openNew();

    await s.importLegacySettings(oldFile);

    expect(s.themeMode, 2);
    expect(s.recentFiles, isEmpty);
  });

  test('a file cut short by a crash still gives up its readable settings',
      () async {
    await seedOldBox({'fontFamily': 'Consolas', 'fontSize': 18.0});
    await File(oldFile)
        .writeAsBytes([9, 9, 9, 9, 9, 9, 9], mode: FileMode.append);
    final s = await openNew();

    await s.importLegacySettings(oldFile);

    expect(s.fontFamily, 'Consolas');
    expect(s.fontSize, 18.0);
  });

  test('the temporary copy is removed', () async {
    List<String> leftovers() => Directory.systemTemp
        .listSync()
        .map((e) => e.path)
        .where((p) => p.contains('scrib_settings_import_'))
        .toList();
    final before = leftovers();
    await seedOldBox(oldValues);
    final s = await openNew();

    await s.importLegacySettings(oldFile);

    expect(leftovers(), before);
  });

  test('a damaged old file is skipped and the settings still work', () async {
    await File(oldFile).writeAsBytes([1, 2, 3, 4, 5, 6, 7, 8, 9]);
    final s = await openNew();

    await s.importLegacySettings(oldFile);

    expect(s.themeMode, 2);
    await s.setThemeMode(1);
    expect(s.themeMode, 1);
    expect(await File(oldFile).readAsBytes(), [1, 2, 3, 4, 5, 6, 7, 8, 9]);
  });
}
