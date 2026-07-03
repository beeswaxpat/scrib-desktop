import 'package:flutter/material.dart';

/// A categorized reference of every keyboard shortcut, opened from Help or F1.
/// Kept in sync by hand with main_screen's _buildShortcuts and the menu bar.
Future<void> showShortcutsDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => const _ShortcutsDialog(),
  );
}

const Map<String, List<List<String>>> _shortcutGroups = {
  'File': [
    ['New tab', 'Ctrl+N'],
    ['Open', 'Ctrl+O'],
    ['Save', 'Ctrl+S'],
    ['Save As', 'Ctrl+Shift+S'],
    ['Close tab', 'Ctrl+W'],
  ],
  'Edit': [
    ['Undo', 'Ctrl+Z'],
    ['Redo', 'Ctrl+Y  /  Ctrl+Shift+Z'],
    ['Cut', 'Ctrl+X'],
    ['Copy', 'Ctrl+C'],
    ['Paste', 'Ctrl+V'],
    ['Select all', 'Ctrl+A'],
  ],
  'Search': [
    ['Find', 'Ctrl+F'],
    ['Find & Replace', 'Ctrl+H'],
    ['Search all tabs', 'Ctrl+Shift+F'],
    ['Close find / search', 'Esc'],
  ],
  'View': [
    ['Increase text size', 'Ctrl+='],
    ['Decrease text size', 'Ctrl+-'],
    ['Default text size', 'Ctrl+0'],
  ],
  'Tabs': [
    ['Next tab', 'Ctrl+Tab'],
    ['Previous tab', 'Ctrl+Shift+Tab'],
  ],
  'Editor': [
    ['Toggle Plain / Rich text', 'Ctrl+M'],
    ['Encrypt / Decrypt', 'Ctrl+E'],
    ['Lock / Unlock tab', 'Ctrl+L'],
    ['Command palette', 'Ctrl+Shift+P'],
    ['Keyboard shortcuts', 'F1'],
  ],
};

class _ShortcutsDialog extends StatelessWidget {
  const _ShortcutsDialog();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('Keyboard Shortcuts'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final entry in _shortcutGroups.entries) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 12, bottom: 4),
                  child: Text(
                    entry.key,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: scheme.primary,
                    ),
                  ),
                ),
                for (final row in entry.value)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(child: Text(row[0], style: const TextStyle(fontSize: 13))),
                        Text(
                          row[1],
                          style: TextStyle(
                            fontSize: 12,
                            fontFamily: 'Consolas',
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
