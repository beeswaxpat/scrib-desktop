import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:scrib_desktop/services/table_embed.dart';

/// The table model: construction, immutable structural edits, the JSON codec,
/// and that a table survives a full Quill Document delta round-trip (which is
/// what gets encrypted inside a .scrb).
void main() {
  group('construction', () {
    test('empty table has the requested shape and blank cells', () {
      final t = ScribTable.empty(rows: 3, cols: 4, id: 't1');
      expect(t.rows, 3);
      expect(t.cols, 4);
      expect(t.cellAt(0, 0), '');
      expect(t.cellAt(2, 3), '');
    });

    test('size is clamped to the limits', () {
      final big = ScribTable.empty(rows: 999, cols: 999, id: 'x');
      expect(big.rows, ScribTable.maxRows);
      expect(big.cols, ScribTable.maxCols);
      final small = ScribTable.empty(rows: 0, cols: 0, id: 'x');
      expect(small.rows, 1);
      expect(small.cols, 1);
    });
  });

  group('immutable edits', () {
    test('withCell does not mutate the original', () {
      final t = ScribTable.empty(rows: 2, cols: 2, id: 't');
      final t2 = t.withCell(0, 1, 'hi');
      expect(t2.cellAt(0, 1), 'hi');
      expect(t.cellAt(0, 1), ''); // original untouched
    });

    test('addRow / addColumn grow the grid', () {
      final t = ScribTable.empty(rows: 2, cols: 2, id: 't').withCell(0, 0, 'A');
      final r = t.addRow();
      expect(r.rows, 3);
      expect(r.cols, 2);
      expect(r.cellAt(0, 0), 'A'); // preserved
      expect(r.cellAt(2, 0), ''); // new blank row

      final c = t.addColumn();
      expect(c.cols, 3);
      expect(c.cellAt(0, 0), 'A');
      expect(c.cellAt(0, 2), '');
    });

    test('removeRow / removeColumn shrink and are guarded at 1', () {
      final t = ScribTable.empty(rows: 2, cols: 2, id: 't');
      expect(t.removeRow(0).rows, 1);
      expect(t.removeColumn(1).cols, 1);

      final single = ScribTable.empty(rows: 1, cols: 1, id: 't');
      expect(single.removeRow(0).rows, 1); // cannot drop below 1
      expect(single.removeColumn(0).cols, 1);
    });

    test('contentEquals ignores id', () {
      final a = ScribTable.empty(rows: 2, cols: 2, id: 'a').withCell(0, 0, 'x');
      final b = ScribTable.empty(rows: 2, cols: 2, id: 'b').withCell(0, 0, 'x');
      expect(a.contentEquals(b), true);
      expect(a.contentEquals(b.withCell(1, 1, 'y')), false);
    });
  });

  group('JSON codec', () {
    test('toData/fromData round-trip', () {
      final t = ScribTable.empty(rows: 2, cols: 3, id: 'tid')
          .withCell(0, 0, 'A')
          .withCell(1, 2, 'Z');
      final back = ScribTable.fromData(t.toData())!;
      expect(back.id, 'tid');
      expect(back.contentEquals(t), true);
    });

    test('fromData parses a JSON string', () {
      final t = ScribTable.empty(rows: 1, cols: 2, id: 's').withCell(0, 1, 'v');
      final str = jsonEncode(t.toData());
      final back = ScribTable.fromData(str)!;
      expect(back.contentEquals(t), true);
    });

    test('fromData pads ragged or missing cells', () {
      final back = ScribTable.fromData({
        'rows': 2,
        'cols': 3,
        'id': 'r',
        'cells': [
          ['only one'],
        ],
      })!;
      expect(back.rows, 2);
      expect(back.cols, 3);
      expect(back.cellAt(0, 0), 'only one');
      expect(back.cellAt(0, 2), '');
      expect(back.cellAt(1, 0), '');
    });

    test('fromData returns null on garbage', () {
      expect(ScribTable.fromData('not json'), isNull);
      expect(ScribTable.fromData({'nope': true}), isNull);
      expect(ScribTable.fromData(42), isNull);
    });

    test('fromData clamps hostile dimensions before allocating cells', () {
      // Regression: dimensions must be clamped BEFORE the cell loop, or a
      // corrupt/hostile embed with huge rows/cols would freeze or OOM on load.
      // This completes instantly only because the clamp happens first.
      final t = ScribTable.fromData({
        'rows': 1000000,
        'cols': 1000000,
        'id': 'hostile',
        'cells': <dynamic>[],
      })!;
      expect(t.rows, ScribTable.maxRows);
      expect(t.cols, ScribTable.maxCols);
      expect(t.cells.length, ScribTable.maxRows);
      expect(t.cells.first.length, ScribTable.maxCols);
    });
  });

  group('Quill document round-trip', () {
    test('table survives toDelta -> JSON -> fromJson', () {
      final table = ScribTable.empty(rows: 2, cols: 2, id: 'doc1')
          .withCell(0, 0, 'Name')
          .withCell(1, 1, 'value');

      final doc = Document()..insert(0, table.toEmbed());
      final json = jsonEncode(doc.toDelta().toJson());
      final doc2 = Document.fromJson(jsonDecode(json) as List<dynamic>);

      Map<String, dynamic>? customOp;
      for (final op in doc2.toDelta().toList()) {
        final data = op.data;
        if (data is Map && data.containsKey('custom')) {
          customOp = Map<String, dynamic>.from(data);
        }
      }
      expect(customOp, isNotNull);

      final embeddable =
          CustomBlockEmbed.fromJsonString(customOp!['custom'] as String);
      expect(embeddable.type, ScribTable.kType);

      final parsed = ScribTable.fromData(embeddable.data)!;
      expect(parsed.id, 'doc1');
      expect(parsed.contentEquals(table), true);
    });
  });
}
