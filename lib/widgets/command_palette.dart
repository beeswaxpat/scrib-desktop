import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/fuzzy_matcher.dart';

/// A single action the command palette can run. Commands are built fresh each
/// time the palette opens so titles reflect current state (e.g. "Decrypt File"
/// vs "Encrypt File").
class ScribCommand {
  final String category;
  final String title;
  final IconData icon;
  final String? shortcut;
  final VoidCallback action;

  const ScribCommand({
    required this.category,
    required this.title,
    required this.icon,
    required this.action,
    this.shortcut,
  });
}

/// Open the command palette (Ctrl+Shift+P). Fuzzy-searches [commands] by
/// title (falling back to "category title"), runs the selection on Enter or
/// click. The palette closes before the command runs so a command can open
/// its own dialog.
Future<void> showCommandPalette(
  BuildContext context,
  List<ScribCommand> commands,
) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black38,
    builder: (ctx) => _CommandPaletteDialog(commands: commands),
  );
}

class _RankedCommand {
  final ScribCommand command;
  final int score;
  final List<int> titleIndices;

  const _RankedCommand(this.command, this.score, this.titleIndices);
}

class _CommandPaletteDialog extends StatefulWidget {
  final List<ScribCommand> commands;

  const _CommandPaletteDialog({required this.commands});

  @override
  State<_CommandPaletteDialog> createState() => _CommandPaletteDialogState();
}

class _CommandPaletteDialogState extends State<_CommandPaletteDialog> {
  static const double _rowHeight = 44;
  static const int _visibleRows = 10;

  final _queryController = TextEditingController();
  final _scrollController = ScrollController();
  List<_RankedCommand> _results = const [];
  int _selected = 0;

  @override
  void initState() {
    super.initState();
    _results = _rank('');
  }

  @override
  void dispose() {
    _queryController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  List<_RankedCommand> _rank(String query) {
    if (query.trim().isEmpty) {
      return [for (final c in widget.commands) _RankedCommand(c, 0, const [])];
    }
    final q = query.trim();
    final ranked = <_RankedCommand>[];
    for (final c in widget.commands) {
      final onTitle = fuzzyMatch(q, c.title);
      if (onTitle != null) {
        ranked.add(_RankedCommand(c, onTitle.score, onTitle.matchedIndices));
        continue;
      }
      // Fall back to matching across "Category Title" so "sec lock" style
      // queries work; highlight only the characters that landed in the title.
      final combined = '${c.category} ${c.title}';
      final onCombined = fuzzyMatch(q, combined);
      if (onCombined != null) {
        final shift = c.category.length + 1;
        ranked.add(_RankedCommand(
          c,
          onCombined.score - 20,
          [
            for (final i in onCombined.matchedIndices)
              if (i >= shift) i - shift,
          ],
        ));
      }
    }
    ranked.sort((a, b) => b.score.compareTo(a.score));
    return ranked;
  }

  void _onQueryChanged(String query) {
    setState(() {
      _results = _rank(query);
      _selected = 0;
    });
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
  }

  void _moveSelection(int delta) {
    if (_results.isEmpty) return;
    setState(() {
      _selected = (_selected + delta).clamp(0, _results.length - 1);
    });
    // Keep the selected row visible in the fixed-extent list.
    final top = _selected * _rowHeight;
    final bottom = top + _rowHeight;
    final viewTop = _scrollController.offset;
    final viewBottom = viewTop + _visibleRows * _rowHeight;
    if (top < viewTop) {
      _scrollController.jumpTo(top);
    } else if (bottom > viewBottom) {
      _scrollController.jumpTo(bottom - _visibleRows * _rowHeight);
    }
  }

  void _runSelected() {
    if (_selected < 0 || _selected >= _results.length) return;
    final command = _results[_selected].command;
    Navigator.of(context).pop();
    command.action();
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowDown:
        _moveSelection(1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        _moveSelection(-1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.pageDown:
        _moveSelection(_visibleRows);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.pageUp:
        _moveSelection(-_visibleRows);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.numpadEnter:
        _runSelected();
        return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colorScheme = Theme.of(context).colorScheme;
    final listHeight =
        (_results.isEmpty ? 1 : _results.length).clamp(1, _visibleRows) *
            _rowHeight;

    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.only(top: 72),
        child: Material(
          color: isDark ? const Color(0xFF1A1A1A) : Colors.white,
          borderRadius: BorderRadius.circular(10),
          elevation: 16,
          clipBehavior: Clip.antiAlias,
          child: SizedBox(
            width: 560,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Focus(
                  onKeyEvent: _onKeyEvent,
                  child: TextField(
                    controller: _queryController,
                    autofocus: true,
                    onChanged: _onQueryChanged,
                    style: const TextStyle(fontSize: 14),
                    decoration: InputDecoration(
                      hintText: 'Type a command...',
                      prefixIcon:
                          Icon(Icons.search, size: 20, color: colorScheme.primary),
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.all(14),
                    ),
                  ),
                ),
                const Divider(height: 1),
                SizedBox(
                  height: listHeight,
                  child: _results.isEmpty
                      ? Center(
                          child: Text(
                            'No matching commands',
                            style: TextStyle(
                              fontSize: 13,
                              color: isDark
                                  ? const Color(0xFF808080)
                                  : const Color(0xFF666666),
                            ),
                          ),
                        )
                      : ListView.builder(
                          controller: _scrollController,
                          itemCount: _results.length,
                          itemExtent: _rowHeight,
                          itemBuilder: (context, index) => _CommandRow(
                            ranked: _results[index],
                            isSelected: index == _selected,
                            isDark: isDark,
                            onHover: () {
                              if (_selected != index) {
                                setState(() => _selected = index);
                              }
                            },
                            onTap: () {
                              _selected = index;
                              _runSelected();
                            },
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CommandRow extends StatelessWidget {
  final _RankedCommand ranked;
  final bool isSelected;
  final bool isDark;
  final VoidCallback onHover;
  final VoidCallback onTap;

  const _CommandRow({
    required this.ranked,
    required this.isSelected,
    required this.isDark,
    required this.onHover,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final command = ranked.command;
    final baseColor = isDark ? const Color(0xFFE0E0E0) : const Color(0xFF1A1A1A);
    final dimColor = isDark ? const Color(0xFF808080) : const Color(0xFF666666);

    return MouseRegion(
      onEnter: (_) => onHover(),
      child: InkWell(
        onTap: onTap,
        child: Container(
          color: isSelected
              ? colorScheme.primary.withValues(alpha: isDark ? 0.18 : 0.10)
              : null,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            children: [
              Icon(command.icon,
                  size: 18,
                  color: isSelected ? colorScheme.primary : dimColor),
              const SizedBox(width: 12),
              Expanded(
                child: RichText(
                  overflow: TextOverflow.ellipsis,
                  text: _highlightedTitle(
                    command.title,
                    ranked.titleIndices,
                    TextStyle(fontSize: 13.5, color: baseColor),
                    TextStyle(
                      fontSize: 13.5,
                      color: colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                command.category,
                style: TextStyle(fontSize: 11, color: dimColor),
              ),
              if (command.shortcut != null) ...[
                const SizedBox(width: 12),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                      color: isDark
                          ? const Color(0xFF2A2A2A)
                          : const Color(0xFFE0E0E0),
                    ),
                  ),
                  child: Text(
                    command.shortcut!,
                    style: TextStyle(fontSize: 10.5, color: dimColor),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  TextSpan _highlightedTitle(
    String title,
    List<int> indices,
    TextStyle normal,
    TextStyle highlight,
  ) {
    if (indices.isEmpty) return TextSpan(text: title, style: normal);
    final matched = indices.toSet();
    final spans = <TextSpan>[];
    int runStart = 0;
    bool runMatched = matched.contains(0);
    for (int i = 1; i <= title.length; i++) {
      final thisMatched = i < title.length && matched.contains(i);
      if (i == title.length || thisMatched != runMatched) {
        spans.add(TextSpan(
          text: title.substring(runStart, i),
          style: runMatched ? highlight : normal,
        ));
        runStart = i;
        runMatched = thisMatched;
      }
    }
    return TextSpan(children: spans);
  }
}
