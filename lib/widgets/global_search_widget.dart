import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/editor_provider.dart';

/// Search-all-tabs panel. Appears below the tab bar.
/// As the user types, it queries all open tabs and lists matches.
/// Clicking a result switches to that tab and opens the per-tab Find bar
/// pre-populated with the query, automatically jumping to the first match.
class GlobalSearchPanel extends StatefulWidget {
  const GlobalSearchPanel({super.key});

  @override
  State<GlobalSearchPanel> createState() => _GlobalSearchPanelState();
}

class _GlobalSearchPanelState extends State<GlobalSearchPanel> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  List<({int tabIndex, String tabName, int matchCount})> _results = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onQueryChanged(String query, EditorProvider editor) {
    setState(() {
      _results = editor.searchAllTabs(query);
    });
  }

  /// Switch to the tab and open the per-tab find bar pre-populated with the query.
  void _navigate(int tabIndex, EditorProvider editor) {
    editor.setActiveTab(tabIndex);
    editor.openFindWithQuery(_controller.text);
  }

  @override
  Widget build(BuildContext context) {
    final editor = context.read<EditorProvider>();
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
                    onChanged: (q) => _onQueryChanged(q, editor),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              // Close button
              InkWell(
                onTap: () => editor.toggleGlobalSearch(),
                borderRadius: BorderRadius.circular(4),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(Icons.close, size: 16, color: labelColor),
                ),
              ),
            ],
          ),

          // ── Results ──────────────────────────────────────────────────────
          if (_results.isNotEmpty) ...[
            const SizedBox(height: 6),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: _results.length,
                itemBuilder: (_, i) {
                  final r = _results[i];
                  return InkWell(
                    onTap: () => _navigate(r.tabIndex, editor),
                    borderRadius: BorderRadius.circular(4),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                      child: Row(
                        children: [
                          Icon(
                            Icons.description_outlined,
                            size: 13,
                            color: labelColor,
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
          ] else if (_controller.text.isNotEmpty) ...[
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
