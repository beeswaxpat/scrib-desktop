import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/editor_provider.dart';
import '../theme/scrib_colors.dart';
import '../constants.dart';

/// Tabbed file bar with per-tab color dots, close buttons, and double-click rename.
/// Close and rename logic is delegated to MainScreen via callbacks.
class ScribTabBar extends StatefulWidget {
  final void Function(int index) onCloseTab;
  final void Function(int index, String newName) onRenameTab;
  final void Function(int index) onCloseOthers;
  final void Function(int index) onCloseToRight;
  final VoidCallback onCloseAll;

  const ScribTabBar({
    super.key,
    required this.onCloseTab,
    required this.onRenameTab,
    required this.onCloseOthers,
    required this.onCloseToRight,
    required this.onCloseAll,
  });

  @override
  State<ScribTabBar> createState() => _ScribTabBarState();
}

class _ScribTabBarState extends State<ScribTabBar> {
  int? _editingIndex;
  int? _hoveredIndex;
  late TextEditingController _renameController;
  late FocusNode _renameFocus;
  final _tabScrollController = ScrollController();
  final _activeTabKey = GlobalKey();
  int _lastRevealedIndex = -1;

  @override
  void initState() {
    super.initState();
    _renameController = TextEditingController();
    _renameFocus = FocusNode();
    _renameFocus.addListener(_onRenameFocusChange);
  }

  @override
  void dispose() {
    _renameController.dispose();
    _renameFocus.removeListener(_onRenameFocusChange);
    _renameFocus.dispose();
    _tabScrollController.dispose();
    super.dispose();
  }

  void _onRenameFocusChange() {
    if (!_renameFocus.hasFocus && _editingIndex != null) {
      _commitRename();
    }
  }

  /// Escape cancels an in-progress rename (Enter commits, click-away commits —
  /// Explorer / VS Code conventions). Clearing _editingIndex before the
  /// TextField loses focus makes the focus-loss listener a no-op, so nothing
  /// is committed. Handling the key here (nearest to the focused node) also
  /// keeps it from reaching MainScreen's global Escape binding.
  KeyEventResult _onRenameKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      if (_editingIndex != null) {
        setState(() => _editingIndex = null);
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Scroll the active tab fully into view (Ctrl+Tab can land on a tab that is
  /// scrolled outside the strip). The two alignment policies together scroll
  /// only as far as needed, and not at all when the tab is already visible.
  void _revealActiveTab() {
    if (!mounted) return;
    final ctx = _activeTabKey.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      duration: const Duration(milliseconds: 120),
    );
    Scrollable.ensureVisible(
      ctx,
      alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart,
      duration: const Duration(milliseconds: 120),
    );
  }

  void _startRename(int index, String currentName) {
    context.read<EditorProvider>().setActiveTab(index);
    setState(() {
      _editingIndex = index;
      final baseName = currentName.replaceAll(RegExp(r'\.[^.]+$'), '');
      _renameController.text = baseName;
      _renameController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: baseName.length,
      );
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _renameFocus.requestFocus();
    });
  }

  void _commitRename() {
    if (_editingIndex == null) return;
    final newName = _renameController.text.trim();
    final index = _editingIndex!;

    if (newName.isEmpty) {
      setState(() => _editingIndex = null);
      return;
    }

    if (RegExp(r'[/\\:*?"<>|]').hasMatch(newName)) {
      // Show error feedback, keep editing so the user can fix the name
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Name cannot contain: / \\ : * ? " < > |'),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 2),
        ),
      );
      _renameFocus.requestFocus();
      return;
    }

    setState(() => _editingIndex = null);
    widget.onRenameTab(index, newName);
  }

  Future<void> _showTabContextMenu(
    BuildContext context,
    Offset position,
    int index,
    int tabCount,
    String fileName,
  ) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final hasOthers = tabCount > 1;
    final hasRight = index < tabCount - 1;

    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        position & const Size(40, 40),
        Offset.zero & overlay.size,
      ),
      items: [
        const PopupMenuItem(value: 'close', child: Text('Close')),
        PopupMenuItem(
          value: 'others',
          enabled: hasOthers,
          child: const Text('Close Others'),
        ),
        PopupMenuItem(
          value: 'right',
          enabled: hasRight,
          child: const Text('Close to the Right'),
        ),
        const PopupMenuItem(value: 'all', child: Text('Close All')),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'rename', child: Text('Rename')),
      ],
    );
    if (!context.mounted || action == null) return;

    switch (action) {
      case 'close':
        widget.onCloseTab(index);
        break;
      case 'others':
        widget.onCloseOthers(index);
        break;
      case 'right':
        widget.onCloseToRight(index);
        break;
      case 'all':
        widget.onCloseAll();
        break;
      case 'rename':
        _startRename(index, fileName);
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final editor = context.watch<EditorProvider>();
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Keep the active tab visible whenever activation changes (click, Ctrl+Tab,
    // Ctrl+1..9, open-file). Runs post-frame so the tab is laid out first.
    if (editor.activeTabIndex != _lastRevealedIndex) {
      _lastRevealedIndex = editor.activeTabIndex;
      WidgetsBinding.instance.addPostFrameCallback((_) => _revealActiveTab());
    }

    return Container(
      height: 36,
      color: isDark ? const Color(0xFF141414) : const Color(0xFFF0F0F0),
      child: Row(
        children: [
          Expanded(
            child: Scrollbar(
              controller: _tabScrollController,
              child: SingleChildScrollView(
                controller: _tabScrollController,
                scrollDirection: Axis.horizontal,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (int index = 0; index < editor.tabs.length; index++)
                      _buildTab(context, editor, index, colorScheme, isDark),
                  ],
                ),
              ),
            ),
          ),
          _buildNewTabButton(editor, colorScheme),
        ],
      ),
    );
  }

  Widget _buildTab(
    BuildContext context,
    EditorProvider editor,
    int index,
    ColorScheme colorScheme,
    bool isDark,
  ) {
    final tab = editor.tabs[index];
    final isActive = index == editor.activeTabIndex;
    final isHovered = _hoveredIndex == index;
    final tabColor = tab.colorIndex != null
        ? accentColors[tab.colorIndex!.clamp(0, accentColors.length - 1)]
        : null;

    return MouseRegion(
      key: isActive ? _activeTabKey : null,
      onEnter: (_) => setState(() => _hoveredIndex = index),
      onExit: (_) {
        if (_hoveredIndex == index) setState(() => _hoveredIndex = null);
      },
      child: GestureDetector(
                  onTap: () => editor.setActiveTab(index),
                  onDoubleTap: () => _startRename(index, tab.fileName),
                  onTertiaryTapUp: (_) => widget.onCloseTab(index),
                  onSecondaryTapUp: (d) => _showTabContextMenu(
                      context, d.globalPosition, index, editor.tabs.length, tab.fileName),
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 200, minWidth: 100),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: isActive
                          ? (isDark ? const Color(0xFF0D0D0D) : Colors.white)
                          : (isHovered
                              ? (isDark ? const Color(0xFF1E1E1E) : const Color(0xFFE6E6E6))
                              : Colors.transparent),
                      border: Border(
                        bottom: BorderSide(
                          color: isActive
                              ? (tabColor ?? colorScheme.primary)
                              : Colors.transparent,
                          width: 2,
                        ),
                        right: BorderSide(
                          color: isDark ? const Color(0xFF2A2A2A) : const Color(0xFFE0E0E0),
                          width: 1,
                        ),
                      ),
                    ),
                    child: Row(
                      children: [
                        // Color dot
                        if (tabColor != null)
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: tabColor,
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                        // Encryption icon — theme-aware lock color while the
                        // tab is locked (content wiped from memory), accent
                        // when unlocked.
                        if (tab.isEncrypted)
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: Icon(
                              Icons.lock,
                              size: 12,
                              color: tab.isLocked
                                  ? context.scribColors.encryptionLock
                                  : (tabColor ?? colorScheme.primary),
                            ),
                          ),
                        // File name (or inline rename TextField)
                        Expanded(
                          child: _editingIndex == index
                              ? SizedBox(
                                  height: 24,
                                  child: Focus(
                                    onKeyEvent: _onRenameKey,
                                    child: TextField(
                                    controller: _renameController,
                                    focusNode: _renameFocus,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: isDark ? const Color(0xFFE0E0E0) : const Color(0xFF1A1A1A),
                                    ),
                                    decoration: InputDecoration(
                                      contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                      isDense: true,
                                      filled: true,
                                      fillColor: isDark ? const Color(0xFF1A1A1A) : const Color(0xFFF5F5F5),
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(3),
                                        borderSide: BorderSide(color: colorScheme.primary),
                                      ),
                                      focusedBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(3),
                                        borderSide: BorderSide(color: colorScheme.primary),
                                      ),
                                    ),
                                    onSubmitted: (_) => _commitRename(),
                                    ),
                                  ),
                                )
              : Tooltip(
                                  message: tab.filePath ?? tab.fileName,
                                  waitDuration: const Duration(milliseconds: 600),
                                  child: Text(
                                    tab.displayName,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: isActive
                                          ? (isDark ? const Color(0xFFE0E0E0) : const Color(0xFF1A1A1A))
                                          : (isDark ? const Color(0xFF808080) : const Color(0xFF666666)),
                                      fontWeight: isActive ? FontWeight.w500 : FontWeight.normal,
                                    ),
                                  ),
                                ),
                        ),
                        // Close button (hidden during rename)
                        if (_editingIndex != index)
                          Semantics(
                            label: 'Close ${tab.fileName}',
                            button: true,
                            child: InkWell(
                              onTap: () => widget.onCloseTab(index),
                              borderRadius: BorderRadius.circular(4),
                              hoverColor: isDark
                                  ? const Color(0xFF3A3A3A)
                                  : const Color(0xFFD0D0D0),
                              child: Padding(
                                padding: const EdgeInsets.all(2),
                                child: Icon(
                                  Icons.close,
                                  size: 14,
                                  color: (isActive || isHovered)
                                      ? (isDark ? const Color(0xFFB0B0B0) : const Color(0xFF555555))
                                      : (isDark ? const Color(0xFF606060) : const Color(0xFF999999)),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
    );
  }

  Widget _buildNewTabButton(EditorProvider editor, ColorScheme colorScheme) {
    return Semantics(
      label: 'New tab',
      button: true,
      child: Tooltip(
        message: 'New tab (Ctrl+N)',
        waitDuration: const Duration(milliseconds: 500),
        child: InkWell(
          onTap: () => editor.addNewTab(),
          borderRadius: BorderRadius.circular(4),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Icon(
              Icons.add,
              size: 20,
              color: colorScheme.primary,
            ),
          ),
        ),
      ),
    );
  }
}
