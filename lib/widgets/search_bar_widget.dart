import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:provider/provider.dart';
import '../providers/editor_provider.dart';

/// Per-tab Find / Find & Replace bar.
/// - showReplace comes from EditorProvider (Ctrl+F = find only, Ctrl+H = find+replace).
/// - If a pendingFindQuery was set (via global search navigation), it's loaded
///   on init and a findNext() is triggered automatically to jump to the first match.
class ScribSearchBar extends StatefulWidget {
  final QuillController? quillController;

  const ScribSearchBar({super.key, this.quillController});

  @override
  State<ScribSearchBar> createState() => _ScribSearchBarState();
}

class _ScribSearchBarState extends State<ScribSearchBar> {
  final _searchController = TextEditingController();
  final _replaceController = TextEditingController();
  final _searchFocus = FocusNode();
  int _matchCount = 0;
  int _currentMatch = 0;

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
        _updateMatchCount(editor);
        _findNext(editor);
      }
      _searchFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _replaceController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  String _getSearchableText(EditorProvider editor) => editor.searchableText;

  @override
  Widget build(BuildContext context) {
    final editor = context.watch<EditorProvider>();
    final showReplace = editor.showReplace;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colorScheme = Theme.of(context).colorScheme;

    final labelColor = isDark ? const Color(0xFF808080) : const Color(0xFF666666);

    return Container(
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
                    onChanged: (_) => _updateMatchCount(editor),
                    onSubmitted: (_) => _findNext(editor),
                  ),
                ),
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
    );
  }

  void _updateMatchCount(EditorProvider editor) {
    final tab = editor.activeTab;
    if (tab == null || _searchController.text.isEmpty) {
      setState(() { _matchCount = 0; _currentMatch = 0; });
      return;
    }

    final text = _getSearchableText(editor).toLowerCase();
    final query = _searchController.text.toLowerCase();

    final matches = <int>[];
    int index = 0;
    while ((index = text.indexOf(query, index)) != -1) {
      matches.add(index);
      index += query.length;
    }

    int current = 0;
    if (matches.isNotEmpty) {
      final cursorPos = _getCursorPos(tab, text.length);
      current = 1;
      for (int i = 0; i < matches.length; i++) {
        if (matches[i] >= cursorPos) { current = i + 1; break; }
        if (i == matches.length - 1) current = 1;
      }
    }

    setState(() { _matchCount = matches.length; _currentMatch = current; });
  }

  int _getCursorPos(EditorTab tab, int textLength) {
    if (tab.mode == EditorMode.richText && widget.quillController != null) {
      return widget.quillController!.selection.baseOffset.clamp(0, textLength);
    }
    return tab.controller.selection.baseOffset.clamp(0, textLength);
  }

  void _selectMatch(EditorTab tab, int index, int length) {
    if (tab.mode == EditorMode.richText && widget.quillController != null) {
      widget.quillController!.updateSelection(
        TextSelection(baseOffset: index, extentOffset: index + length),
        ChangeSource.local,
      );
    } else {
      tab.controller.selection = TextSelection(
        baseOffset: index,
        extentOffset: index + length,
      );
    }
  }

  void _findNext(EditorProvider editor) {
    final tab = editor.activeTab;
    if (tab == null || _searchController.text.isEmpty) return;

    final text = _getSearchableText(editor);
    final query = _searchController.text;
    final currentPos = _getCursorPos(tab, text.length);

    int nextIndex = text.toLowerCase().indexOf(query.toLowerCase(), currentPos);
    if (nextIndex == -1) nextIndex = text.toLowerCase().indexOf(query.toLowerCase());

    if (nextIndex != -1) {
      _selectMatch(tab, nextIndex, query.length);
      _updateMatchCount(editor);
    }
  }

  void _findPrevious(EditorProvider editor) {
    final tab = editor.activeTab;
    if (tab == null || _searchController.text.isEmpty) return;

    final text = _getSearchableText(editor);
    final query = _searchController.text;
    final currentPos = _getCursorPos(tab, text.length);

    final prevIndex = text.toLowerCase().lastIndexOf(
      query.toLowerCase(),
      currentPos > 0 ? currentPos - 1 : text.length,
    );

    if (prevIndex != -1) {
      _selectMatch(tab, prevIndex, query.length);
      _updateMatchCount(editor);
    }
  }

  void _replaceCurrent(EditorProvider editor) {
    final tab = editor.activeTab;
    if (tab == null) return;

    if (tab.mode == EditorMode.richText && widget.quillController != null) {
      final sel = widget.quillController!.selection;
      if (sel.isCollapsed) { _findNext(editor); return; }
      final len = sel.extentOffset - sel.baseOffset;
      widget.quillController!.replaceText(
        sel.baseOffset, len, _replaceController.text,
        TextSelection.collapsed(offset: sel.baseOffset + _replaceController.text.length),
      );
      editor.onContentChanged();
      _updateMatchCount(editor);
      _findNext(editor);
    } else {
      final selection = tab.controller.selection;
      if (selection.isCollapsed) { _findNext(editor); return; }
      final selectedText = tab.controller.text.substring(selection.start, selection.end);
      if (selectedText.toLowerCase() == _searchController.text.toLowerCase()) {
        final newText = tab.controller.text.replaceRange(
          selection.start, selection.end, _replaceController.text,
        );
        tab.controller.text = newText;
        tab.controller.selection = TextSelection.collapsed(
          offset: selection.start + _replaceController.text.length,
        );
        editor.onContentChanged();
        _updateMatchCount(editor);
        _findNext(editor);
      }
    }
  }

  void _replaceAll(EditorProvider editor) {
    final tab = editor.activeTab;
    if (tab == null || _searchController.text.isEmpty) return;

    if (tab.mode == EditorMode.richText && widget.quillController != null) {
      final text = _getSearchableText(editor);
      final query = _searchController.text;
      final matches = <int>[];
      int idx = 0;
      while ((idx = text.toLowerCase().indexOf(query.toLowerCase(), idx)) != -1) {
        matches.add(idx);
        idx += query.length;
      }
      for (int i = matches.length - 1; i >= 0; i--) {
        widget.quillController!.replaceText(matches[i], query.length, _replaceController.text, null);
      }
      if (matches.isNotEmpty) { editor.onContentChanged(); _updateMatchCount(editor); }
    } else {
      final newText = tab.controller.text.replaceAll(
        RegExp(RegExp.escape(_searchController.text), caseSensitive: false),
        _replaceController.text,
      );
      tab.controller.text = newText;
      editor.onContentChanged();
      _updateMatchCount(editor);
    }
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
    return Tooltip(
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
