import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/editor_provider.dart';
import '../constants.dart';

/// Status bar at the bottom - word count, char count, line/col, encryption status
class ScribStatusBar extends StatelessWidget {
  const ScribStatusBar({super.key});

  @override
  Widget build(BuildContext context) {
    final editor = context.watch<EditorProvider>();
    final tab = editor.activeTab;
    final isDark = Theme.of(context).brightness == Brightness.dark;

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
          _StatusItem(text: 'UTF-8', isDark: isDark),

          const Spacer(),

          if (tab != null) ...[
            _StatusItem(
              text: tab.mode == EditorMode.richText ? 'Rich Text' : 'Plain Text',
              isDark: isDark,
            ),
            _statusDivider(isDark),
            // Encryption status — gold lock when encrypted
            Icon(
              tab.isEncrypted ? Icons.lock : Icons.lock_open,
              size: 13,
              color: tab.isEncrypted
                  ? const Color(0xFFFBBF24)
                  : (isDark ? const Color(0xFF606060) : const Color(0xFF999999)),
            ),
            const SizedBox(width: 4),
            Text(
              tab.isEncrypted
                  ? 'Encrypted (.scrb)'
                  : (tab.filePath?.endsWith('.rtf') == true ? '.rtf' : '.txt'),
              style: TextStyle(
                fontSize: 11,
                color: tab.isEncrypted
                    ? const Color(0xFFFBBF24)
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
