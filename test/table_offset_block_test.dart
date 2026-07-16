import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:scrib_desktop/services/table_embed.dart';
import 'package:scrib_desktop/widgets/table_embed_builder.dart';

/// Regression tests for findTableOffset when the table's line carries a BLOCK
/// format (bullet/ordered/check list, blockquote): flutter_quill then wraps
/// the Line in a Block node, so a walk that only inspects top-level Lines
/// stops finding the embed and every debounced cell commit is silently
/// dropped (typed table data lost on save).
void main() {
  ScribTable? extract(QuillController c, String id) {
    for (final op in c.document.toDelta().toList()) {
      final d = op.data;
      if (d is Map && d.containsKey('custom')) {
        final t = ScribTable.fromCustomEmbedData(d['custom']);
        if (t != null && t.id == id) return t;
      }
    }
    return null;
  }

  test('findTableOffset locates a table whose line is a bullet list item', () {
    final controller = QuillController.basic();
    controller.document.insert(0, 'intro text');
    final table = ScribTable.empty(rows: 1, cols: 1, id: 'inlist');
    controller.updateSelection(
      const TextSelection.collapsed(offset: 10),
      ChangeSource.local,
    );
    insertTableEmbed(controller, table);

    final before = findTableOffset(controller, 'inlist');
    expect(before, isNotNull);

    // Wrap the embed's line in a list Block.
    controller.formatText(before!, 1, Attribute.ul);
    expect(
      controller.document.root.children.whereType<Block>(),
      isNotEmpty,
      reason: 'formatting must actually have produced a Block node',
    );

    final after = findTableOffset(controller, 'inlist');
    expect(after, isNotNull);
    expect(controller.document.toPlainText()[after!], '￼');

    // The commit path (replace in place) still works inside the Block.
    controller.replaceText(
        after, 1, table.withCell(0, 0, 'edited').toEmbed(), null);
    expect(extract(controller, 'inlist')!.cellAt(0, 0), 'edited');
  });

  test('findTableOffset locates a table inside a blockquote', () {
    final controller = QuillController.basic();
    final table = ScribTable.empty(rows: 1, cols: 1, id: 'inquote');
    insertTableEmbed(controller, table);

    final before = findTableOffset(controller, 'inquote');
    controller.formatText(before!, 1, Attribute.blockQuote);

    final after = findTableOffset(controller, 'inquote');
    expect(after, isNotNull);
    expect(controller.document.toPlainText()[after!], '￼');
  });

  test('visitDocumentEmbeds visits embeds in plain lines AND blocks, in order',
      () {
    final controller = QuillController.basic();
    final t1 = ScribTable.empty(rows: 1, cols: 1, id: 'one');
    final t2 = ScribTable.empty(rows: 1, cols: 1, id: 'two');
    insertTableEmbed(controller, t1);
    final o1 = findTableOffset(controller, 'one')!;
    controller.updateSelection(
      TextSelection.collapsed(offset: controller.document.length - 1),
      ChangeSource.local,
    );
    insertTableEmbed(controller, t2);
    // Put only the SECOND table into a list.
    final o2 = findTableOffset(controller, 'two')!;
    controller.formatText(o2, 1, Attribute.ol);

    final seen = <String>[];
    final offsets = <int>[];
    visitDocumentEmbeds(controller.document, (offset, embed) {
      final t = tableFromEmbed(embed);
      if (t != null) {
        seen.add(t.id);
        offsets.add(offset);
      }
      return true;
    });

    expect(seen, ['one', 'two']);
    expect(offsets, [findTableOffset(controller, 'one'), findTableOffset(controller, 'two')]);
    final text = controller.document.toPlainText();
    for (final off in offsets) {
      expect(text[off], '￼');
    }
    expect(offsets.first, o1);
  });

  test('early-stop: returning false halts the walk', () {
    final controller = QuillController.basic();
    insertTableEmbed(controller, ScribTable.empty(rows: 1, cols: 1, id: 'a'));
    controller.updateSelection(
      TextSelection.collapsed(offset: controller.document.length - 1),
      ChangeSource.local,
    );
    insertTableEmbed(controller, ScribTable.empty(rows: 1, cols: 1, id: 'b'));

    var visits = 0;
    visitDocumentEmbeds(controller.document, (offset, embed) {
      visits++;
      return false;
    });
    expect(visits, 1);
  });
}
