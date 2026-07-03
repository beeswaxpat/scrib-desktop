import 'package:flutter_test/flutter_test.dart';
import 'package:scrib_desktop/services/fuzzy_matcher.dart';

void main() {
  group('fuzzyMatch basics', () {
    test('empty query matches everything with score 0', () {
      final m = fuzzyMatch('', 'Save As');
      expect(m, isNotNull);
      expect(m!.score, 0);
      expect(m.matchedIndices, isEmpty);
    });

    test('returns null when a query character is missing', () {
      expect(fuzzyMatch('xyz', 'Save'), isNull);
    });

    test('query characters must appear in order', () {
      expect(fuzzyMatch('ae', 'Save'), isNotNull); // a@1 then e@3
      expect(fuzzyMatch('ea', 'Save'), isNull); // e@3, no a after
    });

    test('is case-insensitive', () {
      expect(fuzzyMatch('SAVE', 'save as'), isNotNull);
      expect(fuzzyMatch('save', 'SAVE AS'), isNotNull);
    });

    test('query longer than target never matches', () {
      expect(fuzzyMatch('abcdef', 'abc'), isNull);
    });

    test('exact match returns all indices', () {
      final m = fuzzyMatch('lock', 'Lock');
      expect(m, isNotNull);
      expect(m!.matchedIndices, [0, 1, 2, 3]);
    });
  });

  group('fuzzyMatch ranking', () {
    test('word-start matches outrank scattered matches', () {
      final lockTab = fuzzyMatch('lt', 'Lock Tab')!;
      final calculator = fuzzyMatch('lt', 'Calculator')!;
      expect(lockTab.score, greaterThan(calculator.score));
    });

    test('shorter target wins when both are prefix matches', () {
      final short = fuzzyMatch('save', 'Save')!;
      final long = fuzzyMatch('save', 'Save As...')!;
      expect(short.score, greaterThan(long.score));
    });

    test('consecutive run outranks gapped match', () {
      final consecutive = fuzzyMatch('tab', 'Next Tab')!;
      final gapped = fuzzyMatch('tab', 'Toggle Auto-Save Bar')!;
      expect(consecutive.score, greaterThan(gapped.score));
    });

    test('anchors on the best occurrence, not the first', () {
      // Greedy-from-first-t would match the 't' in "Insert" then jump; the
      // matcher must prefer anchoring on the word start of "Table".
      final m = fuzzyMatch('ta', 'Insert Table')!;
      expect(m.matchedIndices, [7, 8]);
    });

    test('prefix of the whole string gets the target-start bonus', () {
      final prefix = fuzzyMatch('se', 'Search All Tabs')!;
      final embedded = fuzzyMatch('se', 'Close Search')!;
      expect(prefix.score, greaterThan(embedded.score));
    });
  });
}
