import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/editor_provider.dart';
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
    super.dispose();
  }

  void _onRenameFocusChange() {
    if (!_renameFocus.hasFocus && _editingIndex != null) {
      _commitRename();
    }
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

    return Container(
      height: 36,
      color: isDark ? const Color(0xFF141414) : const Color(0xFFF0F0F0),
      child: Row(
        children: [
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: editor.tabs.length,
              itemBuilder: (context, index) {
                final tab = editor.tabs[index];
                final isActive = index == editor.activeTabIndex;
                final isHovered = _hoveredIndex == index;
                final tabColor = tab.colorIndex != null
                    ? accentColors[tab.colorIndex!.clamp(0, accentColors.length - 1)]
                    : null;

                return MouseRegion(
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
                        // Encryption icon — gold while the tab is locked
                        // (content wiped from memory), accent when unlocked.
                        if (tab.isEncrypted)
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: Icon(
                              Icons.lock,
                              size: 12,
                              color: tab.isLocked
                                  ? const Color(0xFFFBBF24)
                                  : (tabColor ?? colorScheme.primary),
                            ),
                          ),
                        // File name (or inline rename TextField)
                        Expanded(
                          child: _editingIndex == index
                              ? SizedBox(
                                  height: 24,
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
              },
            ),
          ),
          // New tab button
          Semantics(
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
          ),
        ],
      ),
    );
  }
}
