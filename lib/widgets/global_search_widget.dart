import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/editor_provider.dart';

/// Search-all-tabs panel. Appears below the tab bar.
/// As the user types (debounced), it queries all open tabs and lists matches.
/// Enter opens the selected result, Up/Down move the selection, Escape closes
/// the panel (handled by MainScreen). Clicking a result switches to that tab
/// and opens the per-tab Find bar pre-populated with the query, automatically
/// jumping to the first match.
///
/// A locked tab is never searched and never cached: it holds no decrypted
/// content, and the panel refuses it on isLocked rather than trusting that.
class GlobalSearchPanel extends StatefulWidget {
  const GlobalSearchPanel({super.key});

  /// How many rich-tab extractions the mounted panel is holding. Each entry is
  /// a full decrypted note, so this is exposed to let tests pin that the text
  /// is dropped when the query is cleared, a tab locks, or the panel closes.
  @visibleForTesting
  static int debugCachedExtractionCount = 0;

  @override
  State<GlobalSearchPanel> createState() => _GlobalSearchPanelState();
}

/// One result row. Holds the tab OBJECT, never its index: the panel is
/// modeless, so tabs can be closed or reordered while results are displayed
/// and a captured index would then point at the wrong tab.
typedef _SearchResult = ({EditorTab tab, String tabName, int matchCount});

class _GlobalSearchPanelState extends State<GlobalSearchPanel> {
  static const _debounceDuration = Duration(milliseconds: 250);

  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  Timer? _debounce;
  String _query = '';
  int _selected = 0;

  /// Extracted plain text per rich tab, keyed by tab identity. An entry is
  /// valid while the tab's deltaJson is the SAME string object — every edit
  /// stores a freshly encoded string, so identity doubles as a dirty check.
  /// Without this, every keystroke re-parsed every rich tab's full delta JSON
  /// (multi-MB per tab when notes embed images) on the UI thread.
  final Map<EditorTab, ({String source, String text})> _extractCache = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focusNode.dispose();
    // Decrypted note text must not outlive the panel that extracted it.
    _extractCache.clear();
    _syncCacheCount();
    super.dispose();
  }

  void _syncCacheCount() =>
      GlobalSearchPanel.debugCachedExtractionCount = _extractCache.length;

  void _onQueryChanged(String query) {
    _debounce?.cancel();
    _debounce = Timer(_debounceDuration, () {
      if (!mounted) return;
      setState(() {
        _query = query;
        _selected = 0;
      });
    });
  }

  /// Apply a pending debounced query immediately (Enter must act on what the
  /// user sees in the field, not on the last committed query).
  void _flushQuery() {
    _debounce?.cancel();
    _query = _controller.text;
  }

  /// Searchable text of [tab], using the extraction cache for rich tabs.
  /// Extraction goes through [extractSearchableDeltaText], the single shared
  /// helper, so table cell text is findable here exactly as it is in the
  /// per-tab find bar and the word counts.
  String _searchableTextOf(EditorTab tab) {
    // A locked tab's content is wiped by EditorTab.lock(), but refuse it on
    // isLocked rather than relying on that: global search must never surface a
    // locked note, whatever state a future path leaves behind on the tab.
    if (tab.isLocked) return '';
    if (tab.mode != EditorMode.richText) return tab.controller.text;
    final cached = _extractCache[tab];
    if (cached != null && identical(cached.source, tab.deltaJson)) {
      return cached.text;
    }
    final text = extractSearchableDeltaText(tab.deltaJson);
    _extractCache[tab] = (source: tab.deltaJson, text: text);
    _syncCacheCount();
    return text;
  }

  /// Search all open tabs for [query], sorted by match count (desc). Runs
  /// against the provider's CURRENT tab list every build, so closed tabs drop
  /// out of the results and counts stay honest.
  List<_SearchResult> _computeResults(EditorProvider editor, String query) {
    // Drop the cache BEFORE the empty-query return. Every entry is a full
    // decrypted note, and returning early left all of them resident for as
    // long as the panel stayed open on a cleared field: the lock screen
    // promises that content is not in memory.
    if (query.trim().isEmpty) {
      if (_extractCache.isNotEmpty) {
        _extractCache.clear();
        _syncCacheCount();
      }
      return const [];
    }
    // Prune first, so a tab closed or LOCKED since the last search can never
    // be searched from, or kept alive by, a stale entry.
    _extractCache.removeWhere(
        (tab, _) => tab.isLocked || !editor.tabs.contains(tab));
    _syncCacheCount();
    final q = query.toLowerCase();
    final results = <_SearchResult>[];
    for (final tab in editor.tabs) {
      final lower = _searchableTextOf(tab).toLowerCase();
      int count = 0;
      int idx = 0;
      while ((idx = lower.indexOf(q, idx)) != -1) {
        count++;
        idx += q.length;
      }
      if (count > 0) {
        results.add((tab: tab, tabName: tab.displayName, matchCount: count));
      }
    }
    results.sort((a, b) => b.matchCount.compareTo(a.matchCount));
    return results;
  }

  /// Switch to the result's tab (resolved by identity at click time) and open
  /// the per-tab find bar pre-populated with the query.
  void _navigate(EditorTab tab, EditorProvider editor) {
    final index = editor.tabs.indexOf(tab);
    if (index == -1) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('That tab has been closed.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    editor.setActiveTab(index);
    editor.openFindWithQuery(_controller.text);
  }

  /// Up/Down move the selection, Enter opens it. Escape is left to bubble to
  /// MainScreen's binding, which closes the panel.
  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final editor = context.read<EditorProvider>();
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowDown:
        _flushQuery();
        final results = _computeResults(editor, _query);
        if (results.isNotEmpty) {
          setState(() => _selected = (_selected + 1).clamp(0, results.length - 1));
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        _flushQuery();
        final results = _computeResults(editor, _query);
        if (results.isNotEmpty) {
          setState(() => _selected = (_selected - 1).clamp(0, results.length - 1));
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.numpadEnter:
        _flushQuery();
        final results = _computeResults(editor, _query);
        if (results.isNotEmpty) {
          final target = results[_selected.clamp(0, results.length - 1)];
          _navigate(target.tab, editor);
        }
        return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    // watch (not read): tabs closing, opening, or changing content while the
    // panel is open must refresh the result list, or clicks act on stale rows.
    final editor = context.watch<EditorProvider>();
    final results = _computeResults(editor, _query);
    if (_selected >= results.length) {
      _selected = results.isEmpty ? 0 : results.length - 1;
    }
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colorScheme = Theme.of(context).colorScheme;
    final labelColor = isDark ? const Color(0xFF808080) : const Color(0xFF666666);
    final mutedColor = isDark ? const Color(0xFF404040) : const Color(0xFFCCCCCC);

    return Container(
      constraints: const BoxConstraints(maxHeight: 220),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF141414) : const Color(0xFFF0F0F0),
        border: Border(
          bottom: BorderSide(
            color: isDark ? const Color(0xFF2A2A2A) : const Color(0xFFE0E0E0),
          ),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Search field row ─────────────────────────────────────────────
          Row(
            children: [
              Icon(Icons.manage_search, size: 15, color: colorScheme.primary),
              const SizedBox(width: 6),
              Text(
                'Search All Tabs',
                style: TextStyle(
                  fontSize: 12,
                  color: colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SizedBox(
                  height: 28,
                  child: Focus(
                    onKeyEvent: _onKeyEvent,
                    child: TextField(
                      controller: _controller,
                      focusNode: _focusNode,
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
                          borderSide: BorderSide(color: isDark ? const Color(0xFF2A2A2A) : const Color(0xFFE0E0E0)),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(4),
                          borderSide: BorderSide(color: isDark ? const Color(0xFF2A2A2A) : const Color(0xFFE0E0E0)),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(4),
                          borderSide: BorderSide(color: colorScheme.primary),
                        ),
                        hintText: 'Search across all open tabs...',
                        hintStyle: TextStyle(
                          color: mutedColor,
                          fontSize: 13,
                        ),
                      ),
                      onChanged: _onQueryChanged,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              // Close button
              Semantics(
                label: 'Close search all tabs',
                button: true,
                child: Tooltip(
                  message: 'Close (Esc)',
                  waitDuration: const Duration(milliseconds: 500),
                  child: InkWell(
                    onTap: () => editor.toggleGlobalSearch(),
                    borderRadius: BorderRadius.circular(4),
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(Icons.close, size: 16, color: labelColor),
                    ),
                  ),
                ),
              ),
            ],
          ),

          // ── Results ──────────────────────────────────────────────────────
          if (results.isNotEmpty) ...[
            const SizedBox(height: 6),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: results.length,
                itemBuilder: (_, i) {
                  final r = results[i];
                  final isSelected = i == _selected;
                  return InkWell(
                    onTap: () => _navigate(r.tab, editor),
                    borderRadius: BorderRadius.circular(4),
                    child: Container(
                      decoration: BoxDecoration(
                        color: isSelected
                            ? colorScheme.primary
                                .withValues(alpha: isDark ? 0.18 : 0.10)
                            : null,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                      child: Row(
                        children: [
                          Icon(
                            Icons.description_outlined,
                            size: 13,
                            color: isSelected ? colorScheme.primary : labelColor,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              r.tabName,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                color: isDark ? const Color(0xFFCCCCCC) : const Color(0xFF333333),
                              ),
                            ),
                          ),
                          // Match count pill
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: colorScheme.primary.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              '${r.matchCount}',
                              style: TextStyle(
                                fontSize: 11,
                                color: colorScheme.primary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          Icon(Icons.arrow_forward_ios, size: 10, color: mutedColor),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ] else if (_query.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              'No matches in any open tab',
              style: TextStyle(fontSize: 12, color: mutedColor),
            ),
          ],
        ],
      ),
    );
  }
}
