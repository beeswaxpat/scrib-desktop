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

  /// Payload format version written by [toData]. [fromData] refuses a payload
  /// declaring a HIGHER version: parsing it as v1 would drop the keys this
  /// build does not know, and the next cell edit would write the truncated
  /// payload back over the original.
  static const int formatVersion = 1;

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
        'v': formatVersion,
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

      // A newer format is refused rather than downgraded: see [formatVersion].
      final version = (map['v'] as num?)?.toInt() ?? formatVersion;
      if (version > formatVersion) return null;

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
        // A row that is not a list (corrupt or crafted) pads to blanks, the
        // same as a missing row, so one bad row cannot discard the readable
        // content of every other row.
        final dynamic rawRowDyn = r < rawCells.length ? rawCells[r] : null;
        final rawRow = rawRowDyn is List ? rawRowDyn : const <dynamic>[];
        final row = <String>[];
        for (var c = 0; c < cols; c++) {
          row.add(c < rawRow.length ? (rawRow[c] ?? '').toString() : '');
        }
        cells.add(row);
      }

      final id = (map['id'] ?? '').toString();
      return ScribTable(
        id: id.isEmpty ? _derivedId(rows, cols, cells) : id,
        rows: rows,
        cols: cols,
        cells: cells,
      );
    } catch (_) {
      return null;
    }
  }

  /// Stable id for a payload that carries none (hand-edited, written by another
  /// tool, or by a pre-id build).
  ///
  /// The fallback used to be `cells.hashCode`, and List.hashCode is IDENTITY
  /// hashing over a freshly allocated list, so every parse minted a DIFFERENT
  /// id: the embed's ValueKey changed on every rebuild (destroying cell focus
  /// and any armed debounce) and findTableOffset re-parsed to yet another id,
  /// so no cell edit was ever committed. FNV-1a over the content is stable
  /// across parses, and across sessions too (String.hashCode is seeded per run).
  static String _derivedId(int rows, int cols, List<List<String>> cells) {
    var h = 0x811c9dc5;
    void mix(int byte) {
      h = ((h ^ (byte & 0xFF)) * 0x01000193) & 0xFFFFFFFF;
    }

    void mixInt(int value) {
      mix(value);
      mix(value >> 8);
      mix(value >> 16);
    }

    mixInt(rows);
    mixInt(cols);
    for (final row in cells) {
      for (final cell in row) {
        for (final unit in cell.codeUnits) {
          mix(unit);
          mix(unit >> 8);
        }
        mix(0x1f); // cell separator
      }
      mix(0x1e); // row separator
    }
    return 't${h.toRadixString(16)}';
  }

  /// Parses a table from the raw payload of a Delta custom-embed op, i.e. the
  /// value of the 'custom' key in `{'insert': {'custom': '{"scrib-table": ...}'}}`
  /// (which is also what a live custom [Embed] node carries in `value.data`).
  /// Returns null for anything that is not a valid Scrib table.
  static ScribTable? fromCustomEmbedData(dynamic customData) {
    if (customData == null) return null;
    try {
      final decoded =
          customData is String ? jsonDecode(customData) : customData;
      if (decoded is! Map) return null;
      final inner = decoded[kType];
      if (inner == null) return null;
      return fromData(inner);
    } catch (_) {
      return null;
    }
  }

  /// All non-empty cell text joined with newlines, for search and word/char
  /// counts. Newline separators guarantee a query can never falsely match
  /// across two adjacent cells.
  String get searchableCellText => [
        for (final row in cells)
          for (final cell in row)
            if (cell.isNotEmpty) cell,
      ].join('\n');

  /// The Quill embed for inserting/replacing this table in a document.
  BlockEmbed toEmbed() =>
      BlockEmbed.custom(CustomBlockEmbed(kType, jsonEncode(toData())));

  // ── Structural edits (return a new table) ──────────────────────────────────

  /// The same grid under a new [newId]. Used to re-mint a pasted copy that
  /// arrived carrying the original table's id.
  ScribTable withId(String newId) => ScribTable(
        id: newId,
        rows: rows,
        cols: cols,
        cells: [
          for (final row in cells) [...row],
        ],
      );

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
