import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import '../services/table_embed.dart';

/// Monotonic counter so two tables created in the same microsecond differ.
int _tableSeq = 0;

/// A fresh, document-unique table id.
String newTableId() {
  _tableSeq++;
  return 't${DateTime.now().microsecondsSinceEpoch}_$_tableSeq';
}

/// Asks the user for a grid size, then inserts a blank table at the selection.
Future<void> pickAndInsertTable(
  BuildContext context,
  QuillController controller,
) async {
  final size = await showTableSizePicker(context);
  if (size == null) return;
  final table = ScribTable.empty(
    rows: size.rows,
    cols: size.cols,
    id: newTableId(),
  );
  insertTableEmbed(controller, table);
}

/// Inserts [table] as its own block (surrounded by line breaks so Quill renders
/// it as a full-width block rather than inline with neighboring text).
void insertTableEmbed(QuillController controller, ScribTable table) {
  final docLen = controller.document.length;
  final sel = controller.selection;
  var index = (sel.isValid ? sel.start : docLen - 1).clamp(0, docLen - 1);
  final end = (sel.isValid ? sel.end : index).clamp(0, docLen - 1);

  if (end > index) {
    controller.replaceText(index, end - index, '', null);
  }

  final text = controller.document.toPlainText();
  final before = index > 0 ? text[index - 1] : '\n';
  final after = index < text.length ? text[index] : '\n';
  final prefix = before == '\n' ? '' : '\n';
  final suffix = after == '\n' ? '' : '\n';

  var at = index;
  if (prefix.isNotEmpty) {
    controller.replaceText(at, 0, prefix, null);
    at += 1;
  }
  controller.replaceText(at, 0, table.toEmbed(), null);
  at += 1;
  if (suffix.isNotEmpty) {
    controller.replaceText(at, 0, suffix, null);
  }
  controller.updateSelection(
    TextSelection.collapsed(offset: at),
    ChangeSource.local,
  );
}

/// Visits every embed leaf in [document] in document order, passing its
/// absolute document offset. Recurses into Block nodes (lists, blockquotes,
/// code blocks), so an embed whose line carries a block format is still
/// visited — root.children is NOT only Lines. Return false from [visit] to
/// stop the walk early.
void visitDocumentEmbeds(
  Document document,
  bool Function(int offset, Embed embed) visit,
) {
  _visitNodes(document.root.children, 0, visit);
}

bool _visitNodes(
  Iterable<Node> nodes,
  int baseOffset,
  bool Function(int offset, Embed embed) visit,
) {
  var offset = baseOffset;
  for (final node in nodes) {
    if (node is Line) {
      if (node.hasEmbed) {
        var childOffset = offset;
        for (final child in node.children) {
          if (child is Embed && !visit(childOffset, child)) return false;
          childOffset += child.length;
        }
      }
    } else if (node is Block) {
      // Block.length is the sum of its child lines, so recursing with the
      // running offset keeps the arithmetic identical to the flat walk.
      if (!_visitNodes(node.children, offset, visit)) return false;
    }
    offset += node.length;
  }
  return true;
}

/// Parses the Scrib table carried by [embed], or null if it is some other
/// kind of embed (image, unknown custom type, corrupt payload).
ScribTable? tableFromEmbed(Embed embed) {
  if (embed.value.type != BlockEmbed.customType) return null;
  return ScribTable.fromCustomEmbedData(embed.value.data);
}

/// Finds the document offset of the table embed carrying [id], or null if it is
/// no longer present. Custom embeds are detached when handed to the builder, so
/// their `documentOffset` is unusable; we locate the live node by id instead.
int? findTableOffset(QuillController controller, String id) {
  int? found;
  visitDocumentEmbeds(controller.document, (offset, embed) {
    final parsed = tableFromEmbed(embed);
    if (parsed != null && parsed.id == id) {
      found = offset;
      return false;
    }
    return true;
  });
  return found;
}

/// Writes [table] back over the live embed carrying its id, replacing the embed
/// character in place. Returns false when the table is no longer in the
/// document (deleted, or undone out from under the caller).
///
/// Free function rather than a State method so a pending edit can still be
/// flushed after the widget is gone: [State.widget] is unusable once dispose()
/// has run, so the caller captures the controller and the table first.
bool commitTableEdit(QuillController controller, ScribTable table) {
  if (controller.document.documentChangeObserver.isClosed) return false;
  final offset = findTableOffset(controller, table.id);
  if (offset == null) return false;
  final sel = controller.selection;
  controller.replaceText(
    offset,
    1,
    table.toEmbed(),
    sel.isValid ? sel : null,
  );
  return true;
}

/// Re-mints the id of every table embed that repeats an id already seen earlier
/// in the document. Returns true if anything was rewritten.
///
/// Copy/paste re-inserts the sliced Delta verbatim (flutter_quill 11.5.0 has no
/// hook that rewrites an embed payload on the way in), so a pasted table
/// arrives carrying the ORIGINAL's id. [findTableOffset] returns the first
/// match, so a cell edit made in the copy committed into the original and
/// destroyed its data while the copy silently reverted on the next rebuild.
/// Two id-less payloads with identical content derive the same id and collide
/// the same way. The FIRST occurrence keeps the id, so an in-place edit of the
/// original is unaffected.
bool remintDuplicateTableIds(QuillController controller) {
  if (controller.document.documentChangeObserver.isClosed) return false;
  final seen = <String>{};
  final duplicates = <int, ScribTable>{};
  visitDocumentEmbeds(controller.document, (offset, embed) {
    final parsed = tableFromEmbed(embed);
    if (parsed != null && !seen.add(parsed.id)) {
      duplicates[offset] = parsed;
    }
    return true;
  });
  if (duplicates.isEmpty) return false;

  // Back to front so a rewrite can never invalidate an offset still to come.
  final offsets = duplicates.keys.toList()..sort();
  for (final offset in offsets.reversed) {
    final sel = controller.selection;
    controller.replaceText(
      offset,
      1,
      duplicates[offset]!.withId(newTableId()).toEmbed(),
      sel.isValid ? sel : null,
    );
  }
  return true;
}

/// Renders Scrib table embeds as an editable grid. One builder handles all
/// custom embeds and dispatches on the inner type.
class ScribTableEmbedBuilder extends EmbedBuilder {
  const ScribTableEmbedBuilder();

  @override
  String get key => ScribTable.kType;

  @override
  Widget build(BuildContext context, EmbedContext embedContext) {
    final table = ScribTable.fromData(embedContext.node.value.data);
    if (table == null) return _brokenTable(context);

    return _EditableTable(
      key: ValueKey(table.id),
      controller: embedContext.controller,
      table: table,
      readOnly: embedContext.readOnly,
    );
  }

  Widget _brokenTable(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final muted = isDark ? const Color(0xFF808080) : const Color(0xFF999999);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1A1A1A) : const Color(0xFFF0F0F0),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: isDark ? const Color(0xFF3A3A3A) : const Color(0xFFCCCCCC),
        ),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.grid_off, size: 18, color: muted),
        const SizedBox(width: 8),
        Text('Table unavailable', style: TextStyle(fontSize: 12, color: muted)),
      ]),
    );
  }
}

class _EditableTable extends StatefulWidget {
  final QuillController controller;
  final ScribTable table;
  final bool readOnly;

  const _EditableTable({
    super.key,
    required this.controller,
    required this.table,
    required this.readOnly,
  });

  @override
  State<_EditableTable> createState() => _EditableTableState();
}

class _EditableTableState extends State<_EditableTable> {
  late ScribTable _table;
  late List<List<TextEditingController>> _ctrls;
  late List<List<FocusNode>> _nodes;
  Timer? _debounce;

  /// True from the moment an edit lands in [_table] until it has been written
  /// back into the document. While it is set, _table is AHEAD of the document
  /// and must not be reseeded from it.
  bool _commitPending = false;
  bool _hovering = false;
  int _focusedRow = 0;
  int _focusedCol = 0;

  @override
  void initState() {
    super.initState();
    _table = widget.table;
    _buildCells();
    if (!widget.readOnly) {
      // A pasted table carries the id of the table it was copied from, so cell
      // edits in one would commit into the other. Repair after this frame: the
      // document must not be mutated while it is being built.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) remintDuplicateTableIds(widget.controller);
      });
    }
  }

  @override
  void didUpdateWidget(_EditableTable old) {
    super.didUpdateWidget(old);
    // While a commit is pending, _table legitimately holds NEWER content than
    // the document does (nothing has been written yet), so the divergence test
    // below reads as an external edit. flutter_quill rebuilds on selection-only
    // changes, so clicking away or pressing an arrow key inside the debounce
    // window reseeded the cells back to the stale value, destroyed focus, and
    // then let the armed timer commit the reverted text.
    if (_commitPending) return;
    // Only reseed if the document changed the table out from under us (undo,
    // external edit). Our own debounced commits produce an identical table, so
    // we keep the existing controllers and focus.
    if (!_table.contentEquals(widget.table)) {
      _table = widget.table;
      _disposeCells();
      _buildCells();
      setState(() {});
    }
  }

  void _buildCells() {
    _ctrls = List.generate(
      _table.rows,
      (r) => List.generate(
        _table.cols,
        (c) => TextEditingController(text: _table.cellAt(r, c)),
      ),
    );
    _nodes = List.generate(
      _table.rows,
      (r) => List.generate(_table.cols, (c) {
        final node = FocusNode();
        node.addListener(() {
          if (node.hasFocus) {
            _focusedRow = r;
            _focusedCol = c;
          }
        });
        return node;
      }),
    );
  }

  void _disposeCells() {
    for (final row in _ctrls) {
      for (final ctrl in row) {
        ctrl.dispose();
      }
    }
    for (final row in _nodes) {
      for (final node in row) {
        node.dispose();
      }
    }
  }

  @override
  void dispose() {
    // A pending edit lives ONLY in _table: nothing has touched the document, so
    // tab.deltaJson is unchanged and the tab is not even dirty. Cancelling here
    // dropped the text with no unsaved-changes prompt anywhere, and disposal is
    // routine (a tab switch tears every table down for the deferred-build
    // placeholder frame). Flush instead of cancel.
    //
    // On a microtask rather than inline: dispose() runs inside the locked
    // widget-tree teardown, where mutating the document would mark a still-live
    // editor as needing a build. The controller and the table are captured
    // because `widget` is unusable once dispose() has returned.
    if (_commitPending) {
      final controller = widget.controller;
      final pending = _table;
      scheduleMicrotask(() => commitTableEdit(controller, pending));
    }
    _debounce?.cancel();
    _disposeCells();
    super.dispose();
  }

  void _onCellChanged(int r, int c, String value) {
    _table = _table.withCell(r, c, value);
    _commitPending = true;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), _commit);
  }

  /// Writes the current model back into the document in place. Cell controllers
  /// and focus nodes are owned by this State (kept stable via the embed's
  /// ValueKey), so the resulting rebuild does not disturb the cursor.
  void _commit() {
    _commitPending = false;
    if (!commitTableEdit(widget.controller, _table) && kDebugMode) {
      // Only reachable when the embed vanished from the document (deleted or
      // undone out from under us). Surface it in debug builds so a lost cell
      // edit is never completely silent.
      debugPrint(
          'ScribTable ${_table.id}: embed not found, cell edit not committed');
    }
  }

  void _structuralChange(ScribTable next) {
    _debounce?.cancel();
    // The new shape reaches the document only in the post-frame commit below,
    // so until then _table is ahead of it exactly as a debounced cell edit is.
    _commitPending = true;
    setState(() {
      _table = next;
      _disposeCells();
      _buildCells();
    });
    // Commit after the rebuild so offsets are current.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _commit();
    });
  }

  void _addRow() => _structuralChange(_table.addRow());
  void _addColumn() => _structuralChange(_table.addColumn());

  void _deleteRow() {
    if (_table.rows <= 1) return;
    final index = _focusedRow.clamp(0, _table.rows - 1);
    _structuralChange(_table.removeRow(index));
  }

  void _deleteColumn() {
    if (_table.cols <= 1) return;
    final index = _focusedCol.clamp(0, _table.cols - 1);
    _structuralChange(_table.removeColumn(index));
  }

  void _deleteTable() {
    _debounce?.cancel();
    // The table is going away: a queued edit must not be flushed back into the
    // document (or into whatever ends up carrying this id) on dispose.
    _commitPending = false;
    final offset = findTableOffset(widget.controller, _table.id);
    if (offset == null) return;
    widget.controller.replaceText(
      offset,
      1,
      '',
      TextSelection.collapsed(offset: offset),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = Theme.of(context).colorScheme.primary;
    final gridColor =
        isDark ? const Color(0xFF3A3A3A) : const Color(0xFFD5D5D5);
    final headerBg =
        isDark ? const Color(0xFF1E1E1E) : const Color(0xFFF2F2F2);
    final textColor =
        isDark ? const Color(0xFFE0E0E0) : const Color(0xFF1A1A1A);

    final showControls = _hovering && !widget.readOnly;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Floating control row (reserve height so the table does not jump).
            SizedBox(
              height: 30,
              child: AnimatedOpacity(
                opacity: showControls ? 1 : 0,
                duration: const Duration(milliseconds: 120),
                child: IgnorePointer(
                  ignoring: !showControls,
                  child: _TableControls(
                    isDark: isDark,
                    accent: accent,
                    canDeleteRow: _table.rows > 1,
                    canDeleteCol: _table.cols > 1,
                    onAddRow: _addRow,
                    onAddCol: _addColumn,
                    onDeleteRow: _deleteRow,
                    onDeleteCol: _deleteColumn,
                    onDeleteTable: _deleteTable,
                  ),
                ),
              ),
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 820),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: gridColor),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Table(
                    defaultColumnWidth: const IntrinsicColumnWidth(),
                    border: TableBorder.symmetric(
                      inside: BorderSide(color: gridColor),
                    ),
                    defaultVerticalAlignment:
                        TableCellVerticalAlignment.middle,
                    children: [
                      for (var r = 0; r < _table.rows; r++)
                        TableRow(
                          decoration: BoxDecoration(
                            color: r == 0 ? headerBg : null,
                          ),
                          children: [
                            for (var c = 0; c < _table.cols; c++)
                              _buildCell(r, c, isDark, accent, textColor),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCell(
      int r, int c, bool isDark, Color accent, Color textColor) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 96, maxWidth: 280),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: TextField(
          controller: _ctrls[r][c],
          focusNode: _nodes[r][c],
          readOnly: widget.readOnly,
          maxLines: null,
          minLines: 1,
          textInputAction: TextInputAction.newline,
          style: TextStyle(
            fontSize: 13,
            height: 1.4,
            color: textColor,
            fontWeight: r == 0 ? FontWeight.w600 : FontWeight.normal,
          ),
          cursorColor: accent,
          decoration: InputDecoration(
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(vertical: 6),
            border: InputBorder.none,
            hintText: r == 0 ? 'Header' : null,
            hintStyle: TextStyle(
              color: isDark ? const Color(0xFF505050) : const Color(0xFFBBBBBB),
              fontSize: 13,
            ),
          ),
          onChanged: (v) => _onCellChanged(r, c, v),
          onTap: () {
            _focusedRow = r;
            _focusedCol = c;
          },
        ),
      ),
    );
  }
}

class _TableControls extends StatelessWidget {
  final bool isDark;
  final Color accent;
  final bool canDeleteRow;
  final bool canDeleteCol;
  final VoidCallback onAddRow;
  final VoidCallback onAddCol;
  final VoidCallback onDeleteRow;
  final VoidCallback onDeleteCol;
  final VoidCallback onDeleteTable;

  const _TableControls({
    required this.isDark,
    required this.accent,
    required this.canDeleteRow,
    required this.canDeleteCol,
    required this.onAddRow,
    required this.onAddCol,
    required this.onDeleteRow,
    required this.onDeleteCol,
    required this.onDeleteTable,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: isDark ? const Color(0xFF202020) : Colors.white,
      elevation: 2,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ctl(Icons.add, 'Add row', onAddRow),
            _ctl(Icons.add_box_outlined, 'Add column', onAddCol),
            _sep(),
            _ctl(Icons.remove, 'Delete current row',
                canDeleteRow ? onDeleteRow : null),
            _ctl(Icons.indeterminate_check_box_outlined, 'Delete current column',
                canDeleteCol ? onDeleteCol : null),
            _sep(),
            _ctl(Icons.delete_outline, 'Delete table', onDeleteTable,
                danger: true),
          ],
        ),
      ),
    );
  }

  Widget _sep() => Container(
        width: 1,
        height: 18,
        margin: const EdgeInsets.symmetric(horizontal: 3),
        color: isDark ? const Color(0xFF383838) : const Color(0xFFE0E0E0),
      );

  Widget _ctl(IconData icon, String tip, VoidCallback? onTap,
      {bool danger = false}) {
    final disabled = onTap == null;
    final color = disabled
        ? (isDark ? const Color(0xFF454545) : const Color(0xFFCCCCCC))
        : danger
            ? const Color(0xFFE57373)
            : (isDark ? const Color(0xFFC0C0C0) : const Color(0xFF555555));
    return Tooltip(
      message: tip,
      waitDuration: const Duration(milliseconds: 400),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.all(5),
          child: Icon(icon, size: 17, color: color),
        ),
      ),
    );
  }
}

// ── Table size picker ────────────────────────────────────────────────────────

/// Shows a hover-to-size grid picker. Returns the chosen size, or null.
Future<({int rows, int cols})?> showTableSizePicker(BuildContext context) {
  return showDialog<({int rows, int cols})>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.35),
    builder: (_) => const _TableSizePicker(),
  );
}

class _TableSizePicker extends StatefulWidget {
  const _TableSizePicker();

  @override
  State<_TableSizePicker> createState() => _TableSizePickerState();
}

class _TableSizePickerState extends State<_TableSizePicker> {
  static const int _maxRows = 10;
  static const int _maxCols = 8;
  static const double _cell = 22;
  static const double _gap = 4;

  int _rows = 1;
  int _cols = 1;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = Theme.of(context).colorScheme.primary;
    final surface = isDark ? const Color(0xFF1A1A1A) : Colors.white;
    final textColor = isDark ? const Color(0xFFE0E0E0) : const Color(0xFF1A1A1A);
    final emptyCell = isDark ? const Color(0xFF2A2A2A) : const Color(0xFFEDEDED);

    return Dialog(
      backgroundColor: surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Insert table',
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: textColor)),
            const SizedBox(height: 4),
            Text('$_cols x $_rows',
                style: TextStyle(
                    fontSize: 12,
                    color: isDark
                        ? const Color(0xFF909090)
                        : const Color(0xFF888888))),
            const SizedBox(height: 10),
            for (var r = 0; r < _maxRows; r++)
              Padding(
                padding: const EdgeInsets.only(bottom: _gap),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var c = 0; c < _maxCols; c++)
                      Padding(
                        padding: const EdgeInsets.only(right: _gap),
                        child: MouseRegion(
                          onEnter: (_) =>
                              setState(() {
                            _rows = r + 1;
                            _cols = c + 1;
                          }),
                          child: GestureDetector(
                            onTap: () => Navigator.of(context)
                                .pop((rows: r + 1, cols: c + 1)),
                            child: Container(
                              width: _cell,
                              height: _cell,
                              decoration: BoxDecoration(
                                color: (r < _rows && c < _cols)
                                    ? accent.withValues(alpha: 0.7)
                                    : emptyCell,
                                borderRadius: BorderRadius.circular(3),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
