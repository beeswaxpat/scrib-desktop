import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/editor_provider.dart';
import '../constants.dart';

/// Tabbed file bar with per-tab color dots, close buttons, and double-click rename.
/// Close and rename logic is delegated to MainScreen via callbacks.
class ScribTabBar extends StatefulWidget {
  final void Function(int index) onCloseTab;
  final void Function(int index, String newName) onRenameTab;

  const ScribTabBar({
    super.key,
    required this.onCloseTab,
    required this.onRenameTab,
  });

  @override
  State<ScribTabBar> createState() => _ScribTabBarState();
}

class _ScribTabBarState extends State<ScribTabBar> {
  int? _editingIndex;
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
                final tabColor = tab.colorIndex != null
                    ? accentColors[tab.colorIndex!.clamp(0, accentColors.length - 1)]
                    : null;

                return GestureDetector(
                  onTap: () => editor.setActiveTab(index),
                  onDoubleTap: () => _startRename(index, tab.fileName),
                  onTertiaryTapUp: (_) => widget.onCloseTab(index),
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 200, minWidth: 100),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: isActive
                          ? (isDark ? const Color(0xFF0D0D0D) : Colors.white)
                          : Colors.transparent,
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
                        // Encryption icon
                        if (tab.isEncrypted)
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: Icon(
                              Icons.lock,
                              size: 12,
                              color: tabColor ?? colorScheme.primary,
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
                              : Text(
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
                        // Close button (hidden during rename)
                        if (_editingIndex != index)
                          InkWell(
                            onTap: () => widget.onCloseTab(index),
                            borderRadius: BorderRadius.circular(4),
                            child: Padding(
                              padding: const EdgeInsets.all(2),
                              child: Icon(
                                Icons.close,
                                size: 14,
                                color: isDark ? const Color(0xFF606060) : const Color(0xFF999999),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          // New tab button
          InkWell(
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
        ],
      ),
    );
  }
}
