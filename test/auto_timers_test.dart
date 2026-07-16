import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:scrib_desktop/providers/editor_provider.dart';
import 'package:scrib_desktop/services/file_service.dart';
import 'package:scrib_desktop/services/settings_service.dart';

/// Trigger wiring for the auto-save and auto-lock timers. The settings values
/// and inner save/lock loops are covered elsewhere; these tests pin that the
/// timers actually FIRE the right provider methods (and stop when disabled),
/// so a refactor cannot silently disable idle locking or background saves
/// while every other test stays green.
///
/// Auto-lock idle time comes from the injectable provider clock, and the poll
/// interval is shortened, so no test waits anywhere near a real minute.
void main() {
  late Directory tmp;
  late SettingsService settings;
  late FileService fs;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('scrib_timers_');
    settings = SettingsService();
    await settings.initForTests(tmp.path);
    fs = FileService();
  });

  tearDown(() async {
    await Hive.close();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  String p(String name) => '${tmp.path}${Platform.pathSeparator}$name';

  /// Polls [condition] until true or [timeout] elapses.
  Future<void> waitFor(
    bool Function() condition, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final sw = Stopwatch()..start();
    while (!condition() && sw.elapsed < timeout) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }

  group('auto-lock trigger wiring', () {
    test('locks a lockable encrypted tab once idle time crosses the threshold', () async {
      await settings.setAutoLockMinutes(1);
      var now = DateTime(2026, 1, 1, 12);
      final editor = EditorProvider(
        fs,
        settings,
        now: () => now,
        autoLockPollInterval: const Duration(milliseconds: 40),
      );
      addTearDown(editor.dispose);

      final scrb = p('a.scrb');
      await fs.writeScrbFile(scrb, 'secret', 'pw', iterations: 1000);
      await editor.openScrbFile(scrb, 'pw');
      final tab = editor.activeTab!;
      expect(tab.canLock, isTrue);

      // 59 seconds idle: under the 1-minute threshold, must stay unlocked.
      now = now.add(const Duration(seconds: 59));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(tab.isLocked, isFalse);

      // Cross the threshold: the poll must fire lockAllEncrypted.
      now = now.add(const Duration(seconds: 2));
      await waitFor(() => tab.isLocked);
      expect(tab.isLocked, isTrue);
      expect(tab.password, isNull);
      expect(tab.controller.text, isEmpty);
    });

    test('noteActivity resets the idle clock', () async {
      await settings.setAutoLockMinutes(1);
      var now = DateTime(2026, 1, 1, 12);
      final editor = EditorProvider(
        fs,
        settings,
        now: () => now,
        autoLockPollInterval: const Duration(milliseconds: 40),
      );
      addTearDown(editor.dispose);

      final scrb = p('b.scrb');
      await fs.writeScrbFile(scrb, 'secret', 'pw', iterations: 1000);
      await editor.openScrbFile(scrb, 'pw');
      final tab = editor.activeTab!;

      // 50s idle, then activity: the idle clock restarts.
      now = now.add(const Duration(seconds: 50));
      editor.noteActivity();

      // 30 more seconds (80s wall, but only 30s idle): must stay unlocked.
      now = now.add(const Duration(seconds: 30));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(tab.isLocked, isFalse,
          reason: 'activity must reset the idle clock');

      // 31 more seconds (61s idle): locks.
      now = now.add(const Duration(seconds: 31));
      await waitFor(() => tab.isLocked);
      expect(tab.isLocked, isTrue);
    });

    test('setting auto-lock to 0 cancels the timer', () async {
      await settings.setAutoLockMinutes(1);
      var now = DateTime(2026, 1, 1, 12);
      final editor = EditorProvider(
        fs,
        settings,
        now: () => now,
        autoLockPollInterval: const Duration(milliseconds: 40),
      );
      addTearDown(editor.dispose);

      final scrb = p('c.scrb');
      await fs.writeScrbFile(scrb, 'secret', 'pw', iterations: 1000);
      await editor.openScrbFile(scrb, 'pw');
      final tab = editor.activeTab!;

      await settings.setAutoLockMinutes(0); // settings listener cancels timer

      now = now.add(const Duration(hours: 2));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(tab.isLocked, isFalse,
          reason: 'auto-lock off must mean no idle locking, ever');
    });
  });

  group('auto-save trigger wiring', () {
    test('writes a dirty file-backed tab after the interval elapses', () async {
      await settings.setAutoSaveInterval(1); // 1 second
      final editor = EditorProvider(fs, settings);
      addTearDown(editor.dispose);

      final txt = p('auto.txt');
      await fs.writeTxtFile(txt, 'v1');
      await editor.openFile(txt);
      editor.activeTab!.controller.text = 'v2 autosaved';
      expect(editor.activeTab!.isDirty, isTrue);

      final sw = Stopwatch()..start();
      while (sw.elapsed < const Duration(seconds: 5)) {
        if (await fs.readTxtFile(txt) == 'v2 autosaved') break;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(await fs.readTxtFile(txt), 'v2 autosaved',
          reason: 'the auto-save timer must fire the background save');
      expect(editor.activeTab!.isDirty, isFalse);
    });

    test('setting the interval to 0 cancels the timer', () async {
      await settings.setAutoSaveInterval(1);
      final editor = EditorProvider(fs, settings);
      addTearDown(editor.dispose);

      final txt = p('nosave.txt');
      await fs.writeTxtFile(txt, 'v1');
      await editor.openFile(txt);

      await settings.setAutoSaveInterval(0); // settings listener cancels timer
      editor.activeTab!.controller.text = 'must not be written';

      await Future<void>.delayed(const Duration(milliseconds: 1600));
      expect(await fs.readTxtFile(txt), 'v1');
      expect(editor.activeTab!.isDirty, isTrue);
    });
  });
}
