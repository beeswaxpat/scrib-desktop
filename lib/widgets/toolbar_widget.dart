import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/editor_provider.dart';
import '../services/settings_service.dart';
import '../constants.dart';

/// Quick-action toolbar with file ops, encrypt, find, font controls, colors, theme.
class ScribToolbar extends StatelessWidget {
  final VoidCallback onOpenFile;
  final VoidCallback onSaveFile;
  final VoidCallback onSaveFileAs;
  final VoidCallback onToggleMode;
  final VoidCallback onToggleEncryption;

  const ScribToolbar({
    super.key,
    required this.onOpenFile,
    required this.onSaveFile,
    required this.onSaveFileAs,
    required this.onToggleMode,
    required this.onToggleEncryption,
  });

  @override
  Widget build(BuildContext context) {
    final isDirty = context.select<EditorProvider, bool>((e) => e.activeTab?.isDirty ?? false);
    final isEncrypted = context.select<EditorProvider, bool>((e) => e.activeTab?.isEncrypted ?? false);
    final mode = context.select<EditorProvider, EditorMode?>((e) => e.activeTab?.mode);
    final colorIndex = context.select<EditorProvider, int?>((e) => e.activeTab?.colorIndex);
    final hasTab = context.select<EditorProvider, bool>((e) => e.activeTab != null);
    final isSearchOpen = context.select<EditorProvider, bool>((e) => e.showSearch);
    final isGlobalSearchOpen = context.select<EditorProvider, bool>((e) => e.showGlobalSearch);
    final tabFontFamily = context.select<EditorProvider, String>((e) => e.activeTab?.tabFontFamily ?? 'Calibri');
    final tabFontSize = context.select<EditorProvider, double>((e) => e.activeTab?.tabFontSize ?? 14.0);

    final editor = context.read<EditorProvider>();
    final settings = context.read<SettingsService>();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colorScheme = Theme.of(context).colorScheme;
    final textColor = isDark ? const Color(0xFFB0B0B0) : const Color(0xFF555555);
    final isRichText = mode == EditorMode.richText;

    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF141414) : const Color(0xFFF0F0F0),
        border: Border(
          bottom: BorderSide(
            color: isDark ? const Color(0xFF2A2A2A) : const Color(0xFFE0E0E0),
          ),
        ),
      ),
      child: Row(
        children: [
          _ToolbarButton(
            icon: Icons.save,
            tooltip: 'Save (Ctrl+S)',
            onPressed: isDirty ? onSaveFile : null,
            isDark: isDark,
          ),
          _ToolbarButton(
            icon: Icons.note_add_outlined,
            tooltip: 'New (Ctrl+N)',
            onPressed: () => editor.addNewTab(),
            isDark: isDark,
          ),
          _ToolbarButton(
            icon: Icons.folder_open_outlined,
            tooltip: 'Open (Ctrl+O)',
            onPressed: onOpenFile,
            isDark: isDark,
          ),

          _toolbarDivider(isDark),

          _ToolbarButton(
            icon: isEncrypted ? Icons.lock : Icons.lock_open,
            tooltip: isEncrypted ? 'Decrypt (Ctrl+E)' : 'Encrypt (Ctrl+E)',
            onPressed: hasTab ? onToggleEncryption : null,
            isDark: isDark,
            activeColor: isEncrypted ? const Color(0xFFFBBF24) : null,
          ),
          // Find (current tab) — Ctrl+F
          _ToolbarButton(
            icon: Icons.search,
            tooltip: 'Find (Ctrl+F)  ·  Find & Replace (Ctrl+H)',
            onPressed: () => editor.openFind(),
            isDark: isDark,
            activeColor: isSearchOpen ? colorScheme.primary : null,
          ),
          _ToolbarButton(
            icon: Icons.manage_search,
            tooltip: 'Search All Tabs (Ctrl+Shift+F)',
            onPressed: () => editor.toggleGlobalSearch(),
            isDark: isDark,
            activeColor: isGlobalSearchOpen ? colorScheme.primary : null,
          ),

          _toolbarDivider(isDark),

          Tooltip(
            message: mode == EditorMode.richText
                ? 'Switch to Plain Text (Ctrl+M)'
                : 'Switch to Rich Text (Ctrl+M)',
            waitDuration: const Duration(milliseconds: 500),
            child: InkWell(
              onTap: hasTab ? onToggleMode : null,
              borderRadius: BorderRadius.circular(4),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: isRichText
                      ? colorScheme.primary.withValues(alpha: 0.15)
                      : null,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                    color: isRichText
                        ? colorScheme.primary
                        : (isDark ? const Color(0xFF3A3A3A) : const Color(0xFFCCCCCC)),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.text_format,
                      size: 15,
                      color: isRichText
                          ? colorScheme.primary
                          : (!hasTab
                              ? (isDark ? const Color(0xFF404040) : const Color(0xFFCCCCCC))
                              : textColor),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      isRichText ? 'Rich Text' : 'Plain Text',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: isRichText
                            ? colorScheme.primary
                            : (!hasTab
                                ? (isDark ? const Color(0xFF404040) : const Color(0xFFCCCCCC))
                                : textColor),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          if (!isRichText) ...[
            _toolbarDivider(isDark),

            SizedBox(
              width: 130,
              height: 26,
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: systemFonts.contains(tabFontFamily)
                      ? tabFontFamily
                      : systemFonts.first,
                  isDense: true,
                  style: TextStyle(fontSize: 12, color: textColor),
                  dropdownColor: isDark ? const Color(0xFF1E1E1E) : Colors.white,
                  icon: Icon(Icons.arrow_drop_down, size: 16, color: textColor),
                  items: systemFonts.map((font) => DropdownMenuItem(
                    value: font,
                    child: Text(font, style: TextStyle(fontFamily: font, fontSize: 12)),
                  )).toList(),
                  onChanged: hasTab
                      ? (value) {
                          if (value != null) editor.setTabFontFamily(value);
                        }
                      : null,
                ),
              ),
            ),

            const SizedBox(width: 4),

            _ToolbarButton(
              icon: Icons.remove,
              tooltip: 'Decrease Text Size (Ctrl+-)',
              onPressed: hasTab
                  ? () => editor.setTabFontSize(tabFontSize - 1)
                  : null,
              isDark: isDark,
            ),
            Tooltip(
              message: 'Click to set custom size',
              waitDuration: const Duration(milliseconds: 500),
              child: InkWell(
                onTap: hasTab ? () async {
                  final size = await _showFontSizeInput(context, tabFontSize, isDark);
                  if (size != null) editor.setTabFontSize(size);
                } : null,
                borderRadius: BorderRadius.circular(4),
                child: Container(
                  width: 34,
                  height: 26,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                      color: isDark ? const Color(0xFF3A3A3A) : const Color(0xFFCCCCCC),
                    ),
                  ),
                  child: Text(
                    '${tabFontSize.round()}',
                    style: TextStyle(fontSize: 11, color: textColor),
                  ),
                ),
              ),
            ),
            _ToolbarButton(
              icon: Icons.add,
              tooltip: 'Increase Text Size (Ctrl+=)',
              onPressed: hasTab
                  ? () => editor.setTabFontSize(tabFontSize + 1)
                  : null,
              isDark: isDark,
            ),
          ],

          const Spacer(),

          ...List.generate(accentColors.length, (i) {
            final isSelected = colorIndex == i;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: InkWell(
                onTap: hasTab ? () => editor.setTabColor(isSelected ? null : i) : null,
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    color: accentColors[i],
                    shape: BoxShape.circle,
                    border: isSelected
                        ? Border.all(color: Colors.white, width: 2)
                        : null,
                  ),
                ),
              ),
            );
          }),

          const SizedBox(width: 8),

          _ToolbarButton(
            icon: isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
            tooltip: isDark ? 'Switch to Light Mode' : 'Switch to Dark Mode',
            onPressed: () => settings.setThemeMode(isDark ? 1 : 2),
            isDark: isDark,
          ),
        ],
      ),
    );
  }

  Widget _toolbarDivider(bool isDark) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      child: Container(
        width: 1,
        color: isDark ? const Color(0xFF2A2A2A) : const Color(0xFFE0E0E0),
      ),
    );
  }
}

Future<double?> _showFontSizeInput(BuildContext context, double current, bool isDark) async {
  final controller = TextEditingController(text: '${current.round()}');
  final result = await showDialog<double>(
    context: context,
    builder: (ctx) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      title: const Text('Set Text Size'),
      content: TextField(
        controller: controller,
        autofocus: true,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(
          labelText: 'Font size (6–144)',
          border: OutlineInputBorder(),
          enabledBorder: OutlineInputBorder(),
          focusedBorder: OutlineInputBorder(),
        ),
        onSubmitted: (value) {
          final parsed = double.tryParse(value);
          if (parsed != null) {
            Navigator.pop(ctx, parsed.clamp(6, 144));
          }
        },
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            final parsed = double.tryParse(controller.text);
            if (parsed != null) {
              Navigator.pop(ctx, parsed.clamp(6, 144));
            }
          },
          child: const Text('Apply'),
        ),
      ],
    ),
  );
  controller.dispose();
  return result;
}

class _ToolbarButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool isDark;
  final Color? activeColor;

  const _ToolbarButton({
    required this.icon,
    required this.tooltip,
    this.onPressed,
    required this.isDark,
    this.activeColor,
  });

  @override
  Widget build(BuildContext context) {
    final isDisabled = onPressed == null;
    final color = activeColor ??
        (isDisabled
            ? (isDark ? const Color(0xFF404040) : const Color(0xFFCCCCCC))
            : (isDark ? const Color(0xFFB0B0B0) : const Color(0xFF555555)));

    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(icon, size: 18, color: color),
        ),
      ),
    );
  }
}
