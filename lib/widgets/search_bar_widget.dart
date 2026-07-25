import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:provider/provider.dart';
import '../providers/editor_provider.dart';
import 'table_embed_builder.dart';

/// Per-tab Find / Find & Replace bar.
/// - showReplace comes from EditorProvider (Ctrl+F = find only, Ctrl+H = find+replace).
/// - If a pendingFindQuery was set (via global search navigation), it's loaded
///   on init and a findNext() is triggered automatically to jump to the first
///   match (in rich mode, deferred until that tab's QuillController arrives).
/// - Otherwise the field is prefilled from the editor's current selection.
/// - Options: match case + whole word (kept for the app session only).
/// - Keys (only while focus is inside the bar): Enter next, Shift+Enter
///   previous, F3 next, Shift+F3 previous, Escape close.
///
/// Offset model: in rich-text mode all match offsets come from
/// `document.toPlainText()`, where every embed (image/table) occupies exactly
/// one character — so an index in that string IS a document position and
/// highlight/replace can never drift in notes containing embeds. Table cell
/// text is searched separately (navigating to such a match selects the table);
/// it is never replaced from here because it lives inside the embed payload.
class ScribSearchBar extends StatefulWidget {
  final QuillController? quillController;

  /// Called after a match is selected in PLAIN-text mode. Flutter never
  /// scrolls a programmatic selection into view (only user edits and focus
  /// changes schedule a caret reveal), so Find Next used to move an off-screen
  /// caret with nothing visibly happening. Rich mode needs no hook:
  /// flutter_quill reveals the caret on every controller notification.
  final VoidCallback? onRevealSelection;

  const ScribSearchBar({
    super.key,
    this.quillController,
    this.onRevealSelection,
  });

  /// Reset the session-scoped search options (match case / whole word) so
  /// tests never leak state into each other.
  @visibleForTesting
  static void resetSearchOptions() {
    _ScribSearchBarState._caseSensitive = false;
    _ScribSearchBarState._wholeWord = false;
  }

  @override
  State<ScribSearchBar> createState() => _ScribSearchBarState();
}

/// A single find match. [offset]/[length] are Quill document positions in
/// rich mode and plain string indices in plain-text mode. [inTable] marks a
/// match inside a table embed's cell text: selectable (selects the embed),
/// counted, but excluded from Replace / Replace All.
class _SearchMatch {
  final int offset;
  final int length;
  final bool inTable;
  const _SearchMatch(this.offset, this.length, {this.inTable = false});
}

class _ScribSearchBarState extends State<ScribSearchBar> {
  final _searchController = TextEditingController();
  final _replaceController = TextEditingController();
  final _searchFocus = FocusNode();
  int _matchCount = 0;
  int _currentMatch = 0;

  // Search options. Static so they survive closing and reopening the bar,
  // but deliberately not persisted to settings (session only).
  static bool _caseSensitive = false;
  static bool _wholeWord = false;

  /// Longest editor selection that is still auto-loaded into the find field.
  static const int _maxPrefillLength = 200;

  /// Query handed over by global search, kept until the rich editor's
  /// QuillController for the tab we were sent to actually arrives. The editor
  /// defers a rich tab's first layout by a frame and publishes its controller
  /// in a post-frame callback, so at initState time this bar still sees the
  /// PREVIOUS tab's controller (or none at all) and the one-shot apply either
  /// reported '0 results' or counted the wrong note. Dropped as soon as the
  /// user edits the query themselves.
  String? _pendingFind;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final editor = context.read<EditorProvider>();
      final pending = editor.pendingFindQuery;
      if (pending.isNotEmpty) {
        _searchController.text = pending;
        editor.clearPendingFindQuery();
        _pendingFind = pending;
        _applyPendingFind(editor);
      } else {
        final selected = _selectedEditorText(editor);
        if (selected.isNotEmpty) {
          _searchController.text = selected;
          _updateMatchCount(editor);
        }
      }
      // Select the whole query so typing immediately replaces it.
      _searchController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _searchController.text.length,
      );
      _searchFocus.requestFocus();
    });
  }

  @override
  void didUpdateWidget(covariant ScribSearchBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // This bar has no key, so a tab switch reuses its State and initState can
    // never re-run. The controller for the tab global search sent us to lands
    // here, several frames later; that is the only chance left to honor the
    // handover.
    if (_pendingFind == null ||
        identical(oldWidget.quillController, widget.quillController)) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _pendingFind == null) return;
      _applyPendingFind(context.read<EditorProvider>());
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _replaceController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  /// Jump to the first match of a query carried over from global search.
  /// In rich mode there is nothing to search until a QuillController exists,
  /// and the query stays pending even after a successful apply so a controller
  /// still belonging to the OUTGOING tab cannot swallow the handover.
  void _applyPendingFind(EditorProvider editor) {
    if (_pendingFind == null) return;
    final tab = editor.activeTab;
    if (tab == null) return;
    if (tab.mode == EditorMode.richText) {
      if (widget.quillController == null) return;
    } else {
      _pendingFind = null; // plain mode has no late-arriving controller
    }
    _updateMatchCount(editor);
    _findNext(editor);
  }

  // ── Query matching ─────────────────────────────────────────────────────────

  /// All match start indices of the current query inside [text], honoring the
  /// match-case and whole-word options.
  List<int> _findAllIndices(String text, String query) {
    if (query.isEmpty || text.isEmpty) return const [];
    var haystack = text;
    var needle = query;
    if (!_caseSensitive) {
      final foldedText = text.toLowerCase();
      final foldedQuery = query.toLowerCase();
      // Locale edge (e.g. Turkish dotted I): lowercasing can change string
      // length, which would desync match offsets from the document. Fall back
      // to exact-case matching in that rare case rather than drift.
      if (foldedText.length == text.length &&
          foldedQuery.length == query.length) {
        haystack = foldedText;
        needle = foldedQuery;
      }
    }
    final result = <int>[];
    var idx = 0;
    while ((idx = haystack.indexOf(needle, idx)) != -1) {
      if (!_wholeWord || _isWholeWordAt(haystack, idx, needle.length)) {
        result.add(idx);
        idx += needle.length;
      } else {
        // Step ONE character past a rejected candidate, not a whole needle:
        // a query that can overlap itself ('ab a' inside 'ab ab a') hid the
        // genuine match behind the rejected one, so Replace All left it in the
        // document while reporting there was nothing to replace.
        idx += 1;
      }
    }
    return result;
  }

  static bool _isWholeWordAt(String text, int start, int length) =>
      !_isWordCharEndingAt(text, start) &&
      !_isWordCharStartingAt(text, start + length);

  /// What counts as a word character for whole-word matching: any Unicode
  /// letter, number, combining mark or underscore. This used to be the ASCII
  /// ranges only, so every accented or non-Latin letter read as a boundary and
  /// whole-word Replace All cut accented words in half: the one mode whose job
  /// is to prevent mid-word edits was performing one.
  static final RegExp _wordChar = RegExp(r'[\p{L}\p{N}\p{M}_]', unicode: true);

  static bool _isHighSurrogate(int unit) => unit >= 0xD800 && unit <= 0xDBFF;

  static bool _isLowSurrogate(int unit) => unit >= 0xDC00 && unit <= 0xDFFF;

  /// Whether the character ENDING at [end] (exclusive) is a word character.
  /// Surrogate pairs are read whole, or an astral letter would be tested as a
  /// lone half that matches no Unicode property.
  static bool _isWordCharEndingAt(String text, int end) {
    if (end <= 0 || end > text.length) return false;
    final start = (end >= 2 &&
            _isLowSurrogate(text.codeUnitAt(end - 1)) &&
            _isHighSurrogate(text.codeUnitAt(end - 2)))
        ? end - 2
        : end - 1;
    return _wordChar.hasMatch(text.substring(start, end));
  }

  /// Whether the character STARTING at [start] is a word character.
  static bool _isWordCharStartingAt(String text, int start) {
    if (start < 0 || start >= text.length) return false;
    final end = (_isHighSurrogate(text.codeUnitAt(start)) &&
            start + 1 < text.length &&
            _isLowSurrogate(text.codeUnitAt(start + 1)))
        ? start + 2
        : start + 1;
    return _wordChar.hasMatch(text.substring(start, end));
  }

  bool _equalsQuery(String text, String query) =>
      _caseSensitive ? text == query : text.toLowerCase() == query.toLowerCase();

  /// All matches in the active tab, sorted by position.
  List<_SearchMatch> _computeMatches(EditorProvider editor) {
    final tab = editor.activeTab;
    final query = _searchController.text;
    if (tab == null || query.isEmpty) return const [];

    if (tab.mode == EditorMode.richText) {
      final qc = widget.quillController;
      if (qc == null) return const [];
      final matches = <_SearchMatch>[];
      // Position-faithful text: one char per embed, indices == doc offsets.
      final text = qc.document.toPlainText();
      for (final index in _findAllIndices(text, query)) {
        matches.add(_SearchMatch(index, query.length));
      }
      // Matches inside table cells: counted and navigable (the whole table
      // embed gets selected), but never replaced from the find bar.
      visitDocumentEmbeds(qc.document, (offset, embed) {
        final table = tableFromEmbed(embed);
        if (table != null) {
          final hits = _findAllIndices(table.searchableCellText, query).length;
          for (var i = 0; i < hits; i++) {
            matches.add(_SearchMatch(offset, 1, inTable: true));
          }
        }
        return true;
      });
      matches.sort((a, b) => a.offset.compareTo(b.offset));
      return matches;
    }

    final text = tab.controller.text;
    return [
      for (final index in _findAllIndices(text, query))
        _SearchMatch(index, query.length),
    ];
  }

  /// Text of the live rich document at [offset]..[offset]+[len], or '' when
  /// the range is invalid. Embeds render as U+FFFC, so a range covering an
  /// embed can never pass the equals-query guard.
  String _richTextAt(QuillController qc, int offset, int len) {
    if (offset < 0 || len <= 0 || offset + len > qc.document.length) return '';
    try {
      return qc.document.getPlainText(offset, len);
    } catch (_) {
      return '';
    }
  }

  /// Editor selection start (used as "current position" for previous/count).
  int _selectionStart(EditorTab tab) {
    if (tab.mode == EditorMode.richText) {
      final sel = widget.quillController?.selection;
      return (sel != null && sel.isValid) ? sel.start : 0;
    }
    final sel = tab.controller.selection;
    return sel.isValid ? sel.start : 0;
  }

  /// Editor selection end (used as "search from here" for next).
  int _selectionEnd(EditorTab tab) {
    if (tab.mode == EditorMode.richText) {
      final sel = widget.quillController?.selection;
      return (sel != null && sel.isValid) ? sel.end : 0;
    }
    final sel = tab.controller.selection;
    return sel.isValid ? sel.end : 0;
  }

  /// Currently selected editor text, if usable as a find query (non-empty,
  /// single line, no embeds, at most [_maxPrefillLength] chars).
  String _selectedEditorText(EditorProvider editor) {
    final tab = editor.activeTab;
    if (tab == null || tab.isLocked) return '';
    String text;
    if (tab.mode == EditorMode.richText) {
      final qc = widget.quillController;
      if (qc == null) return '';
      final sel = qc.selection;
      if (!sel.isValid || sel.isCollapsed) return '';
      final len = sel.end - sel.start;
      if (len > _maxPrefillLength) return '';
      text = _richTextAt(qc, sel.start, len);
    } else {
      final sel = tab.controller.selection;
      if (!sel.isValid || sel.isCollapsed) return '';
      if (sel.end - sel.start > _maxPrefillLength) return '';
      if (sel.end > tab.controller.text.length) return '';
      text = tab.controller.text.substring(sel.start, sel.end);
    }
    if (text.contains('\n') ||
        text.contains('￼') ||
        text.trim().isEmpty) {
      return '';
    }
    return text;
  }

  // ── Keyboard (scoped to the find bar's focus subtree) ─────────────────────

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    if (_searchController.text.isEmpty) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    if (key == LogicalKeyboardKey.f3) {
      final editor = context.read<EditorProvider>();
      shift ? _findPrevious(editor) : _findNext(editor);
      return KeyEventResult.handled;
    }
    if ((key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.numpadEnter) &&
        shift) {
      _findPrevious(context.read<EditorProvider>());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final editor = context.watch<EditorProvider>();
    final showReplace = editor.showReplace;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colorScheme = Theme.of(context).colorScheme;

    final labelColor = isDark ? const Color(0xFF808080) : const Color(0xFF666666);

    return Focus(
      onKeyEvent: _handleKeyEvent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1A1A1A) : const Color(0xFFF5F5F5),
          border: Border(
            bottom: BorderSide(
              color: isDark ? const Color(0xFF2A2A2A) : const Color(0xFFE0E0E0),
            ),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── Find row ──────────────────────────────────────────────────────
            Row(
              children: [
                // Toggle replace chevron — click to expand/collapse replace row
                InkWell(
                  onTap: () => editor.toggleReplace(),
                  borderRadius: BorderRadius.circular(4),
                  child: Padding(
                    padding: const EdgeInsets.all(3),
                    child: Icon(
                      showReplace
                          ? Icons.keyboard_arrow_down
                          : Icons.keyboard_arrow_right,
                      size: 16,
                      color: labelColor,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Text('Find', style: TextStyle(fontSize: 12, color: labelColor)),
                const SizedBox(width: 8),
                Expanded(
                  child: SizedBox(
                    height: 28,
                    child: TextField(
                      controller: _searchController,
                      focusNode: _searchFocus,
                      style: TextStyle(
                        fontSize: 13,
                        color: isDark ? const Color(0xFFE0E0E0) : const Color(0xFF1A1A1A),
                      ),
                      decoration: InputDecoration(
                        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                        isDense: true,
                        filled: true,
                        fillColor: isDark ? const Color(0xFF0D0D0D) : Colors.white,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(4),
                          borderSide: BorderSide(
                            color: isDark ? const Color(0xFF2A2A2A) : const Color(0xFFE0E0E0),
                          ),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(4),
                          borderSide: BorderSide(
                            color: isDark ? const Color(0xFF2A2A2A) : const Color(0xFFE0E0E0),
                          ),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(4),
                          borderSide: BorderSide(color: colorScheme.primary),
                        ),
                        hintText: 'Search...',
                        hintStyle: TextStyle(
                          color: isDark ? const Color(0xFF404040) : const Color(0xFFCCCCCC),
                          fontSize: 13,
                        ),
                      ),
                      onChanged: (_) {
                        // The user is driving the query now: stop re-applying
                        // the query global search handed over.
                        _pendingFind = null;
                        _updateMatchCount(editor);
                      },
                      onSubmitted: (_) => _findNext(editor),
                      // Keep focus after Enter so repeated Enter cycles
                      // through matches (default behavior unfocuses on done).
                      onEditingComplete: () {},
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                // Match case toggle
                _SearchToggle(
                  label: 'Aa',
                  tooltip: 'Match case',
                  active: _caseSensitive,
                  isDark: isDark,
                  onTap: () {
                    setState(() => _caseSensitive = !_caseSensitive);
                    _updateMatchCount(editor);
                  },
                ),
                const SizedBox(width: 4),
                // Whole word toggle
                _SearchToggle(
                  label: '|ab|',
                  tooltip: 'Whole word',
                  active: _wholeWord,
                  isDark: isDark,
                  onTap: () {
                    setState(() => _wholeWord = !_wholeWord);
                    _updateMatchCount(editor);
                  },
                ),
                const SizedBox(width: 8),
                // Match count
                SizedBox(
                  width: 60,
                  child: Text(
                    _matchCount > 0
                        ? '$_currentMatch/$_matchCount'
                        : (_searchController.text.isNotEmpty ? '0 results' : ''),
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      fontSize: 11,
                      color: isDark ? const Color(0xFF606060) : const Color(0xFF999999),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                // Previous match
                _SearchButton(
                  icon: Icons.keyboard_arrow_up,
                  tooltip: 'Previous match (Shift+Enter)',
                  onPressed: _searchController.text.isNotEmpty
                      ? () => _findPrevious(editor)
                      : null,
                  isDark: isDark,
                ),
                // Next match
                _SearchButton(
                  icon: Icons.keyboard_arrow_down,
                  tooltip: 'Next match (Enter)',
                  onPressed: _searchController.text.isNotEmpty
                      ? () => _findNext(editor)
                      : null,
                  isDark: isDark,
                ),
                const SizedBox(width: 4),
                // Close
                _SearchButton(
                  icon: Icons.close,
                  tooltip: 'Close (Escape)',
                  onPressed: () => editor.closeSearch(),
                  isDark: isDark,
                ),
              ],
            ),

            // ── Replace row (shown when showReplace == true) ───────────────────
            if (showReplace) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  const SizedBox(width: 23), // aligns with Find label indent
                  const SizedBox(width: 4),
                  Text('Replace', style: TextStyle(fontSize: 12, color: labelColor)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: SizedBox(
                      height: 28,
                      child: TextField(
                        controller: _replaceController,
                        style: TextStyle(
                          fontSize: 13,
                          color: isDark ? const Color(0xFFE0E0E0) : const Color(0xFF1A1A1A),
                        ),
                        decoration: InputDecoration(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                          isDense: true,
                          filled: true,
                          fillColor: isDark ? const Color(0xFF0D0D0D) : Colors.white,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(4),
                            borderSide: BorderSide(
                              color: isDark ? const Color(0xFF2A2A2A) : const Color(0xFFE0E0E0),
                            ),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(4),
                            borderSide: BorderSide(
                              color: isDark ? const Color(0xFF2A2A2A) : const Color(0xFFE0E0E0),
                            ),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(4),
                            borderSide: BorderSide(color: colorScheme.primary),
                          ),
                          hintText: 'Replace with...',
                          hintStyle: TextStyle(
                            color: isDark ? const Color(0xFF404040) : const Color(0xFFCCCCCC),
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _SearchActionButton(
                    label: 'Replace',
                    onPressed: _searchController.text.isNotEmpty
                        ? () => _replaceCurrent(editor)
                        : null,
                    isDark: isDark,
                  ),
                  const SizedBox(width: 4),
                  _SearchActionButton(
                    label: 'All',
                    onPressed: _searchController.text.isNotEmpty
                        ? () => _replaceAll(editor)
                        : null,
                    isDark: isDark,
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ── Count / navigate / replace ─────────────────────────────────────────────

  void _updateMatchCount(EditorProvider editor) {
    final tab = editor.activeTab;
    if (tab == null || _searchController.text.isEmpty) {
      setState(() { _matchCount = 0; _currentMatch = 0; });
      return;
    }

    final matches = _computeMatches(editor);
    int current = 0;
    if (matches.isNotEmpty) {
      final cursorPos = _selectionStart(tab);
      current = 1;
      for (int i = 0; i < matches.length; i++) {
        if (matches[i].offset >= cursorPos) { current = i + 1; break; }
        if (i == matches.length - 1) current = 1;
      }
    }

    setState(() { _matchCount = matches.length; _currentMatch = current; });
  }

  void _selectMatch(EditorTab tab, _SearchMatch match) {
    if (tab.mode == EditorMode.richText) {
      final qc = widget.quillController;
      if (qc == null) return;
      qc.updateSelection(
        TextSelection(
          baseOffset: match.offset,
          extentOffset: match.offset + match.length,
        ),
        ChangeSource.local,
      );
    } else {
      tab.controller.selection = TextSelection(
        baseOffset: match.offset,
        extentOffset: match.offset + match.length,
      );
      // Assigning the selection does not scroll it into view, and the bar
      // deliberately keeps focus on its own field, so without this the match
      // could sit hundreds of lines off-screen and search looked broken.
      widget.onRevealSelection?.call();
    }
  }

  void _findNext(EditorProvider editor) {
    final tab = editor.activeTab;
    if (tab == null || _searchController.text.isEmpty) return;

    final matches = _computeMatches(editor);
    if (matches.isEmpty) {
      _updateMatchCount(editor);
      return;
    }
    final from = _selectionEnd(tab);
    _SearchMatch? target;
    for (final m in matches) {
      if (m.offset >= from) { target = m; break; }
    }
    target ??= matches.first; // wrap around
    _selectMatch(tab, target);
    _updateMatchCount(editor);
  }

  void _findPrevious(EditorProvider editor) {
    final tab = editor.activeTab;
    if (tab == null || _searchController.text.isEmpty) return;

    final matches = _computeMatches(editor);
    if (matches.isEmpty) {
      _updateMatchCount(editor);
      return;
    }
    final from = _selectionStart(tab);
    _SearchMatch? target;
    for (final m in matches.reversed) {
      if (m.offset < from) { target = m; break; }
    }
    target ??= matches.last; // wrap around
    _selectMatch(tab, target);
    _updateMatchCount(editor);
  }

  void _replaceCurrent(EditorProvider editor) {
    final tab = editor.activeTab;
    if (tab == null || _searchController.text.isEmpty) return;
    final query = _searchController.text;

    if (tab.mode == EditorMode.richText) {
      final qc = widget.quillController;
      if (qc == null) return;
      final sel = qc.selection;
      if (!sel.isValid || sel.isCollapsed) { _findNext(editor); return; }
      final len = sel.end - sel.start;
      // Never replace blind: the selection must actually be the queried text.
      // A stale selection, an embed, or a drifted range fails this check and
      // we navigate to a real match instead of destroying content.
      if (len != query.length ||
          !_equalsQuery(_richTextAt(qc, sel.start, len), query)) {
        _findNext(editor);
        return;
      }
      qc.replaceText(
        sel.start, len, _replaceController.text,
        TextSelection.collapsed(offset: sel.start + _replaceController.text.length),
      );
      editor.onContentChanged();
      _updateMatchCount(editor);
      _findNext(editor);
    } else {
      final selection = tab.controller.selection;
      if (!selection.isValid || selection.isCollapsed) { _findNext(editor); return; }
      final text = tab.controller.text;
      // A selection left over from a shrinking Replace All can reach past the
      // end of the content; substring would then throw a RangeError straight
      // out of the button callback. Mirrors the guard in _selectedEditorText.
      if (selection.end > text.length) { _findNext(editor); return; }
      final selectedText = text.substring(selection.start, selection.end);
      if (_equalsQuery(selectedText, query)) {
        _replaceRangePreservingUndo(
          tab,
          start: selection.start,
          end: selection.end,
          replacement: _replaceController.text,
        );
        editor.invalidateTextCache();
        _updateMatchCount(editor);
        _findNext(editor);
      } else {
        _findNext(editor);
      }
    }
  }

  void _replaceAll(EditorProvider editor) {
    final tab = editor.activeTab;
    if (tab == null || _searchController.text.isEmpty) return;
    final query = _searchController.text;
    final replacement = _replaceController.text;

    if (tab.mode == EditorMode.richText) {
      final qc = widget.quillController;
      if (qc == null) return;
      // Text matches only: a match inside a table cell lives in the embed's
      // payload and is deliberately left untouched.
      final matches =
          _computeMatches(editor).where((m) => !m.inTable).toList();
      var replaced = 0;
      // Back to front so earlier offsets stay valid as the document shrinks
      // or grows with each replacement.
      for (final m in matches.reversed) {
        // Re-verify against the live document before every single edit.
        if (!_equalsQuery(_richTextAt(qc, m.offset, m.length), query)) continue;
        qc.replaceText(m.offset, m.length, replacement, null);
        replaced++;
      }
      if (replaced > 0) {
        editor.invalidateTextCache();
      }
      _updateMatchCount(editor);
    } else {
      final text = tab.controller.text;
      final indices = _findAllIndices(text, query);
      if (indices.isEmpty) {
        _updateMatchCount(editor);
        return;
      }
      final buffer = StringBuffer();
      var prev = 0;
      for (final i in indices) {
        buffer
          ..write(text.substring(prev, i))
          ..write(replacement);
        prev = i + query.length;
      }
      buffer.write(text.substring(prev));
      _replaceAllPreservingUndo(tab, newText: buffer.toString());
      editor.invalidateTextCache();
      _updateMatchCount(editor);
    }
  }

  /// Use [TextEditingValue] instead of `controller.text = ...` so the change
  /// participates in the framework's undo history and the cursor lands in a
  /// predictable position after the replacement.
  void _replaceRangePreservingUndo(
    EditorTab tab, {
    required int start,
    required int end,
    required String replacement,
  }) {
    final oldText = tab.controller.text;
    final newText =
        oldText.substring(0, start) + replacement + oldText.substring(end);
    tab.controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: start + replacement.length),
    );
  }

  void _replaceAllPreservingUndo(EditorTab tab, {required String newText}) {
    final oldSelection = tab.controller.selection;
    // Assigning through controller.value skips the range validation the
    // controller.selection setter performs, so BOTH endpoints have to be in
    // range. Checking only the base let a select-all survive a shrinking
    // Replace All, and the next Replace then threw a RangeError on every click.
    final fits = oldSelection.baseOffset <= newText.length &&
        oldSelection.extentOffset <= newText.length;
    tab.controller.value = TextEditingValue(
      text: newText,
      // Collapse selection to end of content if the previous cursor is out of range.
      selection:
          fits ? oldSelection : TextSelection.collapsed(offset: newText.length),
    );
  }
}

// ── Shared button widgets ────────────────────────────────────────────────────

class _SearchButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool isDark;

  const _SearchButton({
    required this.icon,
    this.tooltip = '',
    this.onPressed,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: tooltip,
      button: true,
      enabled: onPressed != null,
      child: Tooltip(
        message: tooltip,
        waitDuration: const Duration(milliseconds: 600),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(4),
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Icon(
              icon,
              size: 16,
              color: onPressed == null
                  ? (isDark ? const Color(0xFF333333) : const Color(0xFFDDDDDD))
                  : (isDark ? const Color(0xFF808080) : const Color(0xFF666666)),
            ),
          ),
        ),
      ),
    );
  }
}

/// Compact on/off option button (match case, whole word).
class _SearchToggle extends StatelessWidget {
  final String label;
  final String tooltip;
  final bool active;
  final VoidCallback onTap;
  final bool isDark;

  const _SearchToggle({
    required this.label,
    required this.tooltip,
    required this.active,
    required this.onTap,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final inactiveBorder =
        isDark ? const Color(0xFF2A2A2A) : const Color(0xFFE0E0E0);
    final inactiveText =
        isDark ? const Color(0xFF808080) : const Color(0xFF666666);

    return Semantics(
      label: tooltip,
      button: true,
      toggled: active,
      child: Tooltip(
        message: tooltip,
        waitDuration: const Duration(milliseconds: 600),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(4),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(4),
              color: active ? accent.withValues(alpha: 0.18) : null,
              border: Border.all(color: active ? accent : inactiveBorder),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: active ? accent : inactiveText,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SearchActionButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final bool isDark;

  const _SearchActionButton({
    required this.label,
    this.onPressed,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: isDark ? const Color(0xFF2A2A2A) : const Color(0xFFE0E0E0),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: onPressed == null
                ? (isDark ? const Color(0xFF333333) : const Color(0xFFDDDDDD))
                : (isDark ? const Color(0xFF808080) : const Color(0xFF666666)),
          ),
        ),
      ),
    );
  }
}
