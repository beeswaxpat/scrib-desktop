import 'package:flutter_test/flutter_test.dart';
import 'package:scrib_desktop/screens/main_screen.dart';

/// Pure helpers behind the new tab shortcuts: Ctrl+1..9 index resolution and
/// the Ctrl+Shift+T closed-tab history.
void main() {
  group('tabIndexForDigit', () {
    test('digits 1-8 map to that tab when it exists', () {
      expect(tabIndexForDigit(1, 3), 0);
      expect(tabIndexForDigit(2, 3), 1);
      expect(tabIndexForDigit(3, 3), 2);
      expect(tabIndexForDigit(8, 8), 7);
    });

    test('out-of-range digits are null', () {
      expect(tabIndexForDigit(4, 3), isNull);
      expect(tabIndexForDigit(8, 2), isNull);
      expect(tabIndexForDigit(0, 3), isNull);
      expect(tabIndexForDigit(10, 3), isNull);
    });

    test('9 always targets the last tab', () {
      expect(tabIndexForDigit(9, 1), 0);
      expect(tabIndexForDigit(9, 3), 2);
      expect(tabIndexForDigit(9, 12), 11);
    });

    test('no tabs means no target', () {
      expect(tabIndexForDigit(1, 0), isNull);
      expect(tabIndexForDigit(9, 0), isNull);
    });
  });

  group('ClosedTabHistory', () {
    test('pops most recently closed first', () {
      final h = ClosedTabHistory()
        ..push(r'C:\notes\a.txt')
        ..push(r'C:\notes\b.txt');
      expect(h.popNextToReopen(const []), r'C:\notes\b.txt');
      expect(h.popNextToReopen(const []), r'C:\notes\a.txt');
      expect(h.popNextToReopen(const []), isNull);
    });

    test('skips paths that are already open', () {
      final h = ClosedTabHistory()
        ..push(r'C:\notes\a.txt')
        ..push(r'C:\notes\b.txt');
      expect(h.popNextToReopen([r'C:\notes\b.txt']), r'C:\notes\a.txt');
      expect(h.isEmpty, isTrue);
    });

    test('open-path comparison is canonical (case and separators)', () {
      final h = ClosedTabHistory()..push(r'C:\notes\a.txt');
      expect(h.popNextToReopen([r'c:/NOTES/A.TXT']), isNull);
    });

    test('re-closing a file moves it to the top instead of duplicating', () {
      final h = ClosedTabHistory()
        ..push(r'C:\notes\a.txt')
        ..push(r'C:\notes\b.txt')
        ..push(r'C:\notes\a.txt');
      expect(h.popNextToReopen(const []), r'C:\notes\a.txt');
      expect(h.popNextToReopen(const []), r'C:\notes\b.txt');
      expect(h.popNextToReopen(const []), isNull);
    });

    test('is capped at 20 entries, dropping the oldest', () {
      final h = ClosedTabHistory();
      for (int i = 0; i < 25; i++) {
        h.push('C:\\notes\\file_$i.txt');
      }
      final popped = <String>[];
      String? next;
      while ((next = h.popNextToReopen(const [])) != null) {
        popped.add(next!);
      }
      expect(popped.length, 20);
      expect(popped.first, r'C:\notes\file_24.txt');
      expect(popped.last, r'C:\notes\file_5.txt');
    });
  });
}
