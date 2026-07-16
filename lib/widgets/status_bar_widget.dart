import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/editor_provider.dart';
import '../theme/scrib_colors.dart';
import '../constants.dart';

/// Status bar at the bottom - word count, char count, line/col, encryption status
class ScribStatusBar extends StatelessWidget {
  const ScribStatusBar({super.key});

  /// File-format label: the encrypted branch is handled by the caller; for
  /// everything else show the file's ACTUAL extension (.md, .json, ...), and
  /// 'untitled' for a tab that has never been saved (it has no on-disk format).
  static String formatLabel(String? filePath) {
    if (filePath == null) return 'untitled';
    final sepIndex =
        filePath.lastIndexOf(RegExp(r'[/\\]'));
    final name = filePath.substring(sepIndex + 1);
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return 'file';
    return name.substring(dot).toLowerCase();
  }

  /// 1-based (line, column) of the caret in [controller]'s text.
  static (int, int) caretLineCol(TextEditingController controller) {
    final text = controller.text;
    final selection = controller.selection;
    final offset = selection.isValid
        ? selection.extentOffset.clamp(0, text.length)
        : 0;
    int line = 1;
    int lastNewline = -1;
    for (int i = 0; i < offset; i++) {
      if (text.codeUnitAt(i) == 0x0A) {
        line++;
        lastNewline = i;
      }
    }
    return (line, offset - lastNewline);
  }

  @override
  Widget build(BuildContext context) {
    final editor = context.watch<EditorProvider>();
    final tab = editor.activeTab;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final encryptionColor = context.scribColors.encryptionLock;

    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF141414) : const Color(0xFFF0F0F0),
        border: Border(
          top: BorderSide(
            color: isDark ? const Color(0xFF2A2A2A) : const Color(0xFFE0E0E0),
          ),
        ),
      ),
      child: Row(
        children: [
          _StatusItem(text: 'Words: ${editor.wordCount}', isDark: isDark),
          _statusDivider(isDark),
          _StatusItem(text: 'Characters: ${editor.charCount}', isDark: isDark),
          _statusDivider(isDark),
          _StatusItem(text: 'Lines: ${editor.lineCount}', isDark: isDark),
          _statusDivider(isDark),
          // Caret position (plain text only — the caret lives in the tab's
          // TextEditingController, which notifies on every selection change).
          if (tab != null && !tab.isLocked && tab.mode == EditorMode.plainText) ...[
            ListenableBuilder(
              listenable: tab.controller,
              builder: (context, _) {
                final (line, col) = caretLineCol(tab.controller);
                return _StatusItem(text: 'Ln $line, Col $col', isDark: isDark);
              },
            ),
            _statusDivider(isDark),
          ],
          _StatusItem(text: 'UTF-8', isDark: isDark),

          const Spacer(),

          if (tab != null) ...[
            _StatusItem(
              text: tab.mode == EditorMode.richText ? 'Rich Text' : 'Plain Text',
              isDark: isDark,
            ),
            _statusDivider(isDark),
            // Encryption status — theme-aware lock color when encrypted
            // (the hardcoded gold was near-invisible on the light status bar).
            Icon(
              tab.isEncrypted ? Icons.lock : Icons.lock_open,
              size: 13,
              color: tab.isEncrypted
                  ? encryptionColor
                  : (isDark ? const Color(0xFF606060) : const Color(0xFF999999)),
            ),
            const SizedBox(width: 4),
            Text(
              tab.isEncrypted
                  ? (tab.isLocked ? 'Locked (.scrb)' : 'Encrypted (.scrb)')
                  : formatLabel(tab.filePath),
              style: TextStyle(
                fontSize: 11,
                color: tab.isEncrypted
                    ? encryptionColor
                    : (isDark ? const Color(0xFF606060) : const Color(0xFF999999)),
              ),
            ),
            _statusDivider(isDark),
          ],

          // App version
          Text(
            'Scrib v$appVersion',
            style: TextStyle(
              fontSize: 11,
              color: isDark ? const Color(0xFF404040) : const Color(0xFFCCCCCC),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusDivider(bool isDark) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Container(
        width: 1,
        height: 14,
        color: isDark ? const Color(0xFF2A2A2A) : const Color(0xFFE0E0E0),
      ),
    );
  }
}

class _StatusItem extends StatelessWidget {
  final String text;
  final bool isDark;

  const _StatusItem({required this.text, required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 11,
        color: isDark ? const Color(0xFF808080) : const Color(0xFF666666),
      ),
    );
  }
}
