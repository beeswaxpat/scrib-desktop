import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:scrib_desktop/services/table_embed.dart';
import 'package:scrib_desktop/widgets/table_embed_builder.dart';

/// Exercises the document-manipulation paths the editable table relies on:
/// inserting a table as its own block, locating it by id (its node is detached
/// when handed to the builder, so offset lookup must scan), committing an edit
/// in place, and deleting it.
void main() {
  ScribTable? extract(QuillController c, String id) {
    for (final op in c.document.toDelta().toList()) {
      final d = op.data;
      if (d is Map && d.containsKey('custom')) {
        final e = CustomBlockEmbed.fromJsonString(d['custom'] as String);
        final t = ScribTable.fromData(e.data);
        if (t != null && t.id == id) return t;
      }
    }
    return null;
  }

  test('insertTableEmbed places a table on its own line', () {
    final controller = QuillController.basic();
    final table = ScribTable.empty(rows: 2, cols: 2, id: 'tbl').withCell(0, 0, 'H');
    insertTableEmbed(controller, table);

    final offset = findTableOffset(controller, 'tbl');
    expect(offset, isNotNull);

    // Block placement: the embed character is alone on its line.
    final text = controller.document.toPlainText();
    expect(text[offset!], '￼'); // object replacement char
    expect(offset == 0 || text[offset - 1] == '\n', true);
    expect(offset + 1 >= text.length || text[offset + 1] == '\n', true);
  });

  test('inserting after typed text keeps the table as its own block', () {
    final controller = QuillController.basic();
    controller.document.insert(0, 'hello');
    controller.updateSelection(
      const TextSelection.collapsed(offset: 5),
      ChangeSource.local,
    );
    final table = ScribTable.empty(rows: 1, cols: 1, id: 'mid');
    insertTableEmbed(controller, table);

    final offset = findTableOffset(controller, 'mid')!;
    final text = controller.document.toPlainText();
    expect(text[offset - 1], '\n');
    expect(text[offset], '￼');
  });

  test('committing an edited table updates it in place, only one table', () {
    final controller = QuillController.basic();
    final table = ScribTable.empty(rows: 2, cols: 2, id: 'tbl');
    insertTableEmbed(controller, table);

    final offset = findTableOffset(controller, 'tbl')!;
    final edited = table.withCell(1, 1, 'X').addColumn();
    controller.replaceText(offset, 1, edited.toEmbed(), null);

    final back = extract(controller, 'tbl')!;
    expect(back.cellAt(1, 1), 'X');
    expect(back.cols, 3);

    // Still exactly one custom embed in the document.
    var count = 0;
    for (final op in controller.document.toDelta().toList()) {
      final d = op.data;
      if (d is Map && d.containsKey('custom')) count++;
    }
    expect(count, 1);
  });

  test('deleting a table removes it from the document', () {
    final controller = QuillController.basic();
    final table = ScribTable.empty(rows: 2, cols: 2, id: 'gone');
    insertTableEmbed(controller, table);

    final offset = findTableOffset(controller, 'gone')!;
    controller.replaceText(
      offset,
      1,
      '',
      TextSelection.collapsed(offset: offset),
    );

    expect(findTableOffset(controller, 'gone'), isNull);
  });
}
