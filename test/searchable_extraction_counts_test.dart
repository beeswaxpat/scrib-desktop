import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:scrib_desktop/providers/editor_provider.dart';
import 'package:scrib_desktop/services/file_service.dart';
import 'package:scrib_desktop/services/settings_service.dart';
import 'package:scrib_desktop/services/table_embed.dart';

/// Covers:
///  * extractSearchableDeltaText — table cell text participates in counts and
///    search; images become a single space so words are never fused;
///  * single-pass computeTextCounts stays identical to the old RegExp-based
///    word/char/line counts;
///  * updateDeltaJson ignores identical JSON (selection-only notifications
///    must not invalidate caches or schedule a notify).
///
/// Search-all-tabs behavior (including table cell matches through the same
/// extraction) is covered at the widget level in global_search_widget_test.dart.
void main() {
  late Directory tmp;
  late SettingsService settings;
  late FileService fs;
  late EditorProvider editor;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('scrib_counts_');
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

  group('extractSearchableDeltaText', () {
    test('plain string ops pass through, trailing newline stripped', () {
      final json = jsonEncode([
        {'insert': 'hello world\n'}
      ]);
      expect(extractSearchableDeltaText(json), 'hello world');
    });

    test('image embeds become a space so surrounding words are not fused', () {
      final json = jsonEncode([
        {'insert': 'foo'},
        {'insert': {'image': 'data:image/png;base64,AA=='}},
        {'insert': 'bar\n'},
      ]);
      expect(extractSearchableDeltaText(json), 'foo bar');
    });

    test('table embeds contribute their cell text, newline-separated', () {
      final table = ScribTable.empty(rows: 2, cols: 2, id: 't')
          .withCell(0, 0, 'alpha beta')
          .withCell(1, 1, 'gamma');
      final json = jsonEncode([
        {'insert': 'head\n'},
        {'insert': table.toEmbed().toJson()},
        {'insert': '\n'},
      ]);
      expect(extractSearchableDeltaText(json), 'head\nalpha beta\ngamma');
    });

    test('empty and malformed input return empty', () {
      expect(extractSearchableDeltaText(''), '');
      expect(extractSearchableDeltaText('not json'), '');
      expect(extractSearchableDeltaText('{"a":1}'), '');
    });
  });

  group('counts', () {
    test('rich-mode counts include table text and are image-safe', () {
      final tab = editor.activeTab!;
      tab.mode = EditorMode.richText;
      final table = ScribTable.empty(rows: 2, cols: 2, id: 't')
          .withCell(0, 0, 'alpha beta')
          .withCell(1, 1, 'gamma');
      tab.deltaJson = jsonEncode([
        {'insert': 'foo'},
        {'insert': {'image': 'data:image/png;base64,AA=='}},
        {'insert': 'bar\n'},
        {'insert': table.toEmbed().toJson()},
        {'insert': '\n'},
      ]);
      editor.invalidateTextCache();
      // "foo bar\nalpha beta\ngamma"
      expect(editor.wordCount, 5);
      expect(editor.charCount, 'foo bar\nalpha beta\ngamma'.length);
      expect(editor.lineCount, 3);
    });

    test('single-pass counts equal the old RegExp-based counts', () {
      const samples = [
        '',
        '   ',
        'one',
        'one  two\tthree\nfour',
        'a\nb\nc',
        '\n\n\n',
        'tab\tseparated  and nbsp emsp',
        'trailing space ',
        ' leading',
        'multi\n\nblank\nlines\n',
        'unicode   line-sep   para-sep',
      ];
      for (final text in samples) {
        final counts = EditorProvider.computeTextCounts(text);
        final expectedWords =
            text.trim().isEmpty ? 0 : RegExp(r'\S+').allMatches(text).length;
        final expectedLines =
            text.isEmpty ? 1 : '\n'.allMatches(text).length + 1;
        expect(counts.words, expectedWords, reason: 'words of "$text"');
        expect(counts.chars, text.length, reason: 'chars of "$text"');
        expect(counts.lines, expectedLines, reason: 'lines of "$text"');
      }
    });

    test('rich-mode counts pin to a regex recount of the extraction', () {
      final tab = editor.activeTab!;
      tab.mode = EditorMode.richText;
      final table = ScribTable.empty(rows: 1, cols: 3, id: 'x')
          .withCell(0, 0, 'a b')
          .withCell(0, 2, 'c');
      tab.deltaJson = jsonEncode([
        {'insert': 'one two\nthree '},
        {'insert': {'image': 'data:image/png;base64,AA=='}},
        {'insert': ' four\n'},
        {'insert': table.toEmbed().toJson()},
        {'insert': '\n'},
      ]);
      editor.invalidateTextCache();
      final extracted = extractSearchableDeltaText(tab.deltaJson);
      expect(editor.wordCount, RegExp(r'\S+').allMatches(extracted).length);
      expect(editor.charCount, extracted.length);
      expect(editor.lineCount, '\n'.allMatches(extracted).length + 1);
    });
  });

  group('updateDeltaJson', () {
    test('identical JSON is a no-op: no dirty flip, no debounced notify',
        () async {
      final tab = editor.activeTab!;
      tab.mode = EditorMode.richText;
      tab.deltaJson = '[{"insert":"a\\n"}]';
      tab.savedDeltaJson = tab.deltaJson;

      var notified = false;
      editor.addListener(() => notified = true);

      editor.updateDeltaJson('[{"insert":"a\\n"}]');
      expect(tab.isDirty, isFalse);
      // Wait past the 150ms debounce: a selection-only change must not notify.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(notified, isFalse);

      editor.updateDeltaJson('[{"insert":"ab\\n"}]');
      expect(tab.deltaJson, '[{"insert":"ab\\n"}]');
      expect(tab.isDirty, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(notified, isTrue);
    });

    test('locked tabs are never written (save-guard invariant)', () {
      final tab = editor.activeTab!;
      tab.mode = EditorMode.richText;
      tab.isLocked = true;
      editor.updateDeltaJson('[{"insert":"leak\\n"}]');
      expect(tab.deltaJson, isEmpty);
    });
  });

}
