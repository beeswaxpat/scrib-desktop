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

  /// Every table embed in [c], in document order.
  List<ScribTable> tablesIn(QuillController c) {
    final found = <ScribTable>[];
    visitDocumentEmbeds(c.document, (offset, embed) {
      final t = tableFromEmbed(embed);
      if (t != null) found.add(t);
      return true;
    });
    return found;
  }

  /// Inserts [table] twice, the second time byte-for-byte as a paste does.
  QuillController withPastedDuplicate(ScribTable table) {
    final controller = QuillController.basic();
    insertTableEmbed(controller, table);
    controller.updateSelection(
      TextSelection.collapsed(offset: controller.document.length - 1),
      ChangeSource.local,
    );
    insertTableEmbed(controller, table);
    return controller;
  }

  test('commitTableEdit reports whether the table was still there', () {
    final controller = QuillController.basic();
    final table = ScribTable.empty(rows: 1, cols: 1, id: 'live');
    insertTableEmbed(controller, table);

    expect(commitTableEdit(controller, table.withCell(0, 0, 'saved')), isTrue);
    expect(extract(controller, 'live')!.cellAt(0, 0), 'saved');

    final gone = ScribTable.empty(rows: 1, cols: 1, id: 'never-inserted');
    expect(commitTableEdit(controller, gone), isFalse);
  });

  test('a pasted duplicate id is re-minted, and the original keeps its id', () {
    // Quill pastes the sliced Delta verbatim, so a copied table arrives with
    // the ORIGINAL's id. findTableOffset returns the first match, so a cell
    // edit in the copy used to commit into the original and destroy its data.
    final table =
        ScribTable.empty(rows: 1, cols: 1, id: 'dup').withCell(0, 0, 'original');
    final controller = withPastedDuplicate(table);
    expect(tablesIn(controller).map((t) => t.id), ['dup', 'dup'],
        reason: 'precondition: the paste really does duplicate the id');

    expect(remintDuplicateTableIds(controller), isTrue);

    final after = tablesIn(controller);
    expect(after.length, 2);
    expect(after.first.id, 'dup', reason: 'the first occurrence keeps the id');
    expect(after.last.id, isNot('dup'));
    expect(after.first.cellAt(0, 0), 'original');
    expect(after.last.cellAt(0, 0), 'original');

    // Each table is now independently addressable: editing the copy leaves the
    // original alone.
    expect(
      commitTableEdit(controller, after.last.withCell(0, 0, 'copy only')),
      isTrue,
    );
    final edited = tablesIn(controller);
    expect(edited.first.cellAt(0, 0), 'original');
    expect(edited.last.cellAt(0, 0), 'copy only');
  });

  test('re-minting is a no-op when every id is already unique', () {
    final controller = QuillController.basic();
    insertTableEmbed(controller, ScribTable.empty(rows: 1, cols: 1, id: 'a'));
    controller.updateSelection(
      TextSelection.collapsed(offset: controller.document.length - 1),
      ChangeSource.local,
    );
    insertTableEmbed(controller, ScribTable.empty(rows: 1, cols: 1, id: 'b'));

    expect(remintDuplicateTableIds(controller), isFalse);
    expect(tablesIn(controller).map((t) => t.id), ['a', 'b']);
  });

  test('two id-less tables with identical content are separated too', () {
    // Their ids are derived from content, so they collide by construction.
    final payload = {
      'rows': 1,
      'cols': 1,
      'cells': [
        ['same'],
      ],
    };
    final table = ScribTable.fromData(payload)!;
    final controller = withPastedDuplicate(table);
    expect(tablesIn(controller)[0].id, tablesIn(controller)[1].id);

    expect(remintDuplicateTableIds(controller), isTrue);
    final after = tablesIn(controller);
    expect(after.first.id, isNot(after.last.id));
    expect(after.every((t) => t.cellAt(0, 0) == 'same'), isTrue);
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
