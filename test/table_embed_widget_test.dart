import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrib_desktop/services/table_embed.dart';
import 'package:scrib_desktop/widgets/table_embed_builder.dart';

/// The editable table keeps the cell text the user is typing OUTSIDE the
/// document until a 500ms debounce commits it. Three ways that state used to be
/// lost or misdirected are pinned here: disposal inside the debounce window
/// (tab switch, Ctrl+W, quit), an editor rebuild inside the same window, and a
/// pasted copy that carries the original's id.
void main() {
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

  Widget harness(QuillController controller) => MaterialApp(
        home: Scaffold(
          body: QuillEditor.basic(
            controller: controller,
            config: const QuillEditorConfig(
              embedBuilders: [ScribTableEmbedBuilder()],
            ),
          ),
        ),
      );

  testWidgets('a pending cell edit is flushed when the table is disposed',
      (t) async {
    final controller = QuillController.basic();
    insertTableEmbed(controller, ScribTable.empty(rows: 1, cols: 1, id: 'f'));

    await t.pumpWidget(harness(controller));
    await t.pump();

    await t.enterText(find.byType(TextField), 'typed');
    expect(tablesIn(controller).single.cellAt(0, 0), '',
        reason: 'precondition: still inside the debounce, nothing committed');

    // Tear the editor down the way a tab switch does, well inside the window.
    await t.pumpWidget(const SizedBox());
    await t.pump();

    expect(tablesIn(controller).single.cellAt(0, 0), 'typed',
        reason: 'dispose must flush the pending commit, not cancel it — the '
            'document was never touched, so the tab was not even dirty and '
            'nothing prompted');
  });

  testWidgets('an editor rebuild inside the debounce window keeps the edit',
      (t) async {
    final controller = QuillController.basic();
    insertTableEmbed(controller, ScribTable.empty(rows: 1, cols: 1, id: 'k'));

    await t.pumpWidget(harness(controller));
    await t.pump();

    await t.enterText(find.byType(TextField), 'half typed');
    await t.pump(const Duration(milliseconds: 100));

    // flutter_quill rebuilds on selection-only changes, which re-runs the embed
    // builder against the still-unmodified document.
    controller.updateSelection(
      const TextSelection.collapsed(offset: 0),
      ChangeSource.local,
    );
    await t.pump();

    expect(find.text('half typed'), findsOneWidget,
        reason: 'the rebuild must not reseed the cell from the stale document');

    await t.pump(const Duration(milliseconds: 600));
    expect(tablesIn(controller).single.cellAt(0, 0), 'half typed',
        reason: 'the armed timer must still commit the typed text');
  });

  testWidgets('a pasted duplicate is re-minted so edits stay in the copy',
      (t) async {
    final controller = QuillController.basic();
    final table =
        ScribTable.empty(rows: 1, cols: 1, id: 'dup').withCell(0, 0, 'original');
    insertTableEmbed(controller, table);
    controller.updateSelection(
      TextSelection.collapsed(offset: controller.document.length - 1),
      ChangeSource.local,
    );
    insertTableEmbed(controller, table); // paste: same payload, same id
    expect(tablesIn(controller).map((e) => e.id), ['dup', 'dup']);

    await t.pumpWidget(harness(controller));
    await t.pump(); // the post-frame repair
    await t.pump(); // the rebuild it triggers

    final ids = tablesIn(controller).map((e) => e.id).toList();
    expect(ids.first, 'dup', reason: 'the original keeps its identity');
    expect(ids.last, isNot('dup'));

    await t.enterText(find.byType(TextField).last, 'copy only');
    await t.pump(const Duration(milliseconds: 600));

    final after = tablesIn(controller);
    expect(after.first.cellAt(0, 0), 'original',
        reason: 'editing the copy must not commit into the original');
    expect(after.last.cellAt(0, 0), 'copy only');
  });
}
