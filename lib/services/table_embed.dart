import 'dart:convert';
import 'package:flutter_quill/flutter_quill.dart';

/// Immutable model for a table embedded in a rich-text note.
///
/// A table is stored as a Quill *custom* block embed. The payload is a JSON
/// string (Quill custom embeds carry a String), so it travels inside the note's
/// Delta and, for a `.scrb`, is AES-256 encrypted alongside the text like any
/// other content. Nothing about a table touches disk in the clear.
class ScribTable {
  /// Inner embed type, used as the [EmbedBuilder] key.
  static const String kType = 'scrib-table';

  static const int maxRows = 60;
  static const int maxCols = 12;

  /// Stable identity, used to keep cell focus across document rebuilds and to
  /// locate this table's offset in the document when committing edits.
  final String id;
  final int rows;
  final int cols;

  /// Row-major cell text: `cells[row][col]`.
  final List<List<String>> cells;

  const ScribTable({
    required this.id,
    required this.rows,
    required this.cols,
    required this.cells,
  });

  /// A blank table of the given size.
  factory ScribTable.empty({
    required int rows,
    required int cols,
    required String id,
  }) {
    final r = rows.clamp(1, maxRows);
    final c = cols.clamp(1, maxCols);
    return ScribTable(
      id: id,
      rows: r,
      cols: c,
      cells: List.generate(
        r,
        (_) => List<String>.filled(c, '', growable: true),
        growable: true,
      ),
    );
  }

  String cellAt(int r, int c) {
    if (r < 0 || r >= rows || c < 0 || c >= cols) return '';
    return cells[r][c];
  }

  /// JSON-serializable form. [v] guards future format changes.
  Map<String, dynamic> toData() => {
        'v': 1,
        'id': id,
        'rows': rows,
        'cols': cols,
        'cells': [
          for (final row in cells) [...row],
        ],
      };

  /// Parses table data from either a JSON string or a decoded Map. Returns null
  /// if the data is not a valid table (the embed renders a fallback instead).
  static ScribTable? fromData(dynamic data) {
    try {
      final Map<String, dynamic> map = data is String
          ? jsonDecode(data) as Map<String, dynamic>
          : Map<String, dynamic>.from(data as Map);

      final rawRows = (map['rows'] as num).toInt();
      final rawCols = (map['cols'] as num).toInt();
      if (rawRows < 1 || rawCols < 1) return null;
      // Clamp BEFORE allocating any cells: a corrupt or hostile embed with huge
      // dimensions must not be able to freeze the UI thread or exhaust memory.
      final rows = rawRows.clamp(1, maxRows);
      final cols = rawCols.clamp(1, maxCols);

      final rawCells = (map['cells'] as List<dynamic>?) ?? const [];
      final cells = <List<String>>[];
      for (var r = 0; r < rows; r++) {
        final rawRow = r < rawCells.length
            ? (rawCells[r] as List<dynamic>)
            : const <dynamic>[];
        final row = <String>[];
        for (var c = 0; c < cols; c++) {
          row.add(c < rawRow.length ? (rawRow[c] ?? '').toString() : '');
        }
        cells.add(row);
      }

      final id = (map['id'] ?? '').toString();
      return ScribTable(
        id: id.isEmpty ? 't${cells.hashCode}' : id,
        rows: rows,
        cols: cols,
        cells: cells,
      );
    } catch (_) {
      return null;
    }
  }

  /// The Quill embed for inserting/replacing this table in a document.
  BlockEmbed toEmbed() =>
      BlockEmbed.custom(CustomBlockEmbed(kType, jsonEncode(toData())));

  // ── Structural edits (return a new table) ──────────────────────────────────

  ScribTable withCell(int r, int c, String value) {
    if (r < 0 || r >= rows || c < 0 || c >= cols) return this;
    final next = [for (final row in cells) [...row]];
    next[r][c] = value;
    return ScribTable(id: id, rows: rows, cols: cols, cells: next);
  }

  ScribTable addRow({int? at}) {
    if (rows >= maxRows) return this;
    final index = (at ?? rows).clamp(0, rows);
    final next = [for (final row in cells) [...row]];
    next.insert(index, List<String>.filled(cols, '', growable: true));
    return ScribTable(id: id, rows: rows + 1, cols: cols, cells: next);
  }

  ScribTable addColumn({int? at}) {
    if (cols >= maxCols) return this;
    final index = (at ?? cols).clamp(0, cols);
    final next = [
      for (final row in cells) [...row]..insert(index, ''),
    ];
    return ScribTable(id: id, rows: rows, cols: cols + 1, cells: next);
  }

  ScribTable removeRow(int index) {
    if (rows <= 1 || index < 0 || index >= rows) return this;
    final next = [for (final row in cells) [...row]]..removeAt(index);
    return ScribTable(id: id, rows: rows - 1, cols: cols, cells: next);
  }

  ScribTable removeColumn(int index) {
    if (cols <= 1 || index < 0 || index >= cols) return this;
    final next = [
      for (final row in cells) ([...row]..removeAt(index)),
    ];
    return ScribTable(id: id, rows: rows, cols: cols - 1, cells: next);
  }

  /// True if the grid shape and every cell value match [other] (ignores id).
  bool contentEquals(ScribTable other) {
    if (rows != other.rows || cols != other.cols) return false;
    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        if (cells[r][c] != other.cells[r][c]) return false;
      }
    }
    return true;
  }
}
