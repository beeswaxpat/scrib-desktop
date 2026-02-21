import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import '../constants.dart';

/// Full-featured formatting toolbar for rich text mode.
/// Provides WordPad-style formatting options: headings, text styling,
/// text color, neon highlights, alignment, lists, indentation,
/// block quotes, and clear formatting.
class ScribFormattingToolbar extends StatelessWidget {
  final QuillController controller;

  const ScribFormattingToolbar({
    super.key,
    required this.controller,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF181818) : const Color(0xFFF5F5F5),
        border: Border(
          bottom: BorderSide(
            color: isDark ? const Color(0xFF2A2A2A) : const Color(0xFFE0E0E0),
          ),
        ),
      ),
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final style = controller.getSelectionStyle();

          // Inline formatting state
          final isBold = style.containsKey(Attribute.bold.key);
          final isItalic = style.containsKey(Attribute.italic.key);
          final isUnderline = style.containsKey(Attribute.underline.key);
          final isStrike = style.containsKey(Attribute.strikeThrough.key);

          // Header level (0 = normal, 1-3 = H1-H3)
          final headerValue = style.attributes[Attribute.header.key]?.value;
          final headerLevel = (headerValue is int) ? headerValue : 0;

          // Alignment
          final alignValue = style.attributes[Attribute.align.key]?.value as String?;

          // Lists
          final listValue = style.attributes[Attribute.list.key]?.value;
          final isBulletList = listValue == 'bullet';
          final isNumberedList = listValue == 'ordered';

          // Block quote
          final isBlockQuote = style.containsKey(Attribute.blockQuote.key);

          // Indent level
          final indentValue = style.attributes[Attribute.indent.key]?.value;
          final indentLevel = (indentValue is int) ? indentValue : 0;

          // Text color
          final textColorHex = style.attributes[Attribute.color.key]?.value as String?;

          // Background/highlight color
          final bgColorHex = style.attributes[Attribute.background.key]?.value as String?;

          // Font family & size for current selection
          final fontValue = style.attributes[Attribute.font.key]?.value as String?;
          final sizeRaw = style.attributes[Attribute.size.key]?.value;
          final currentSize = sizeRaw is num
              ? sizeRaw.toInt()
              : (sizeRaw is String ? int.tryParse(sizeRaw) : null);

          return Row(
            children: [
              // --- Font family dropdown ---
              _FontFamilyDropdown(
                currentFont: fontValue,
                isDark: isDark,
                onSelected: (font) {
                  if (font == null) {
                    controller.formatSelection(Attribute.clone(Attribute.font, null));
                  } else {
                    controller.formatSelection(Attribute.clone(Attribute.font, font));
                  }
                },
              ),

              const SizedBox(width: 4),

              // --- Font size dropdown ---
              _FontSizeDropdown(
                currentSize: currentSize,
                isDark: isDark,
                onSelected: (size) {
                  if (size == null) {
                    controller.formatSelection(Attribute.clone(Attribute.size, null));
                  } else {
                    controller.formatSelection(Attribute.clone(Attribute.size, size));
                  }
                },
              ),

              _divider(isDark),

              // --- Heading dropdown ---
              _HeadingDropdown(
                headerLevel: headerLevel,
                isDark: isDark,
                onSelected: (level) => _setHeading(level),
              ),

              _divider(isDark),

              // --- Text formatting ---
              _FormatButton(
                icon: Icons.format_bold,
                tooltip: 'Bold (Ctrl+B)',
                isActive: isBold,
                onPressed: () => _toggleInline(Attribute.bold),
                isDark: isDark,
              ),
              _FormatButton(
                icon: Icons.format_italic,
                tooltip: 'Italic (Ctrl+I)',
                isActive: isItalic,
                onPressed: () => _toggleInline(Attribute.italic),
                isDark: isDark,
              ),
              _FormatButton(
                icon: Icons.format_underlined,
                tooltip: 'Underline (Ctrl+U)',
                isActive: isUnderline,
                onPressed: () => _toggleInline(Attribute.underline),
                isDark: isDark,
              ),
              _FormatButton(
                icon: Icons.strikethrough_s,
                tooltip: 'Strikethrough',
                isActive: isStrike,
                onPressed: () => _toggleInline(Attribute.strikeThrough),
                isDark: isDark,
              ),

              _divider(isDark),

              // --- Text color ---
              _ColorPickerButton(
                icon: Icons.format_color_text,
                tooltip: 'Text Color',
                colors: textPaletteColors,
                colorNames: textPaletteNames,
                currentHex: textColorHex,
                isDark: isDark,
                onColorSelected: (hex) {
                  if (hex == null || hex.isEmpty) {
                    controller.formatSelection(const ColorAttribute(null));
                  } else {
                    controller.formatSelection(ColorAttribute(hex));
                  }
                },
              ),

              // --- Highlight ---
              _ColorPickerButton(
                icon: Icons.highlight,
                tooltip: 'Highlight',
                colors: neonHighlightColors,
                colorNames: neonHighlightNames,
                currentHex: bgColorHex,
                isDark: isDark,
                onColorSelected: (hex) {
                  if (hex == null || hex.isEmpty) {
                    controller.formatSelection(const BackgroundAttribute(null));
                  } else {
                    controller.formatSelection(BackgroundAttribute(hex));
                  }
                },
              ),

              _divider(isDark),

              // --- Alignment ---
              _FormatButton(
                icon: Icons.format_align_left,
                tooltip: 'Align Left',
                isActive: alignValue == null || alignValue == 'left',
                onPressed: () => _setAlignment(null),
                isDark: isDark,
              ),
              _FormatButton(
                icon: Icons.format_align_center,
                tooltip: 'Align Center',
                isActive: alignValue == 'center',
                onPressed: () => _setAlignment('center'),
                isDark: isDark,
              ),
              _FormatButton(
                icon: Icons.format_align_right,
                tooltip: 'Align Right',
                isActive: alignValue == 'right',
                onPressed: () => _setAlignment('right'),
                isDark: isDark,
              ),
              _FormatButton(
                icon: Icons.format_align_justify,
                tooltip: 'Justify',
                isActive: alignValue == 'justify',
                onPressed: () => _setAlignment('justify'),
                isDark: isDark,
              ),

              _divider(isDark),

              // --- Lists ---
              _FormatButton(
                icon: Icons.format_list_bulleted,
                tooltip: 'Bullet List',
                isActive: isBulletList,
                onPressed: () => _toggleBlock(Attribute.ul, style),
                isDark: isDark,
              ),
              _FormatButton(
                icon: Icons.format_list_numbered,
                tooltip: 'Numbered List',
                isActive: isNumberedList,
                onPressed: () => _toggleBlock(Attribute.ol, style),
                isDark: isDark,
              ),

              _divider(isDark),

              // --- Indentation ---
              _FormatButton(
                icon: Icons.format_indent_decrease,
                tooltip: 'Decrease Indent',
                isActive: false,
                onPressed: indentLevel > 0
                    ? () => _changeIndent(indentLevel, -1)
                    : null,
                isDark: isDark,
              ),
              _FormatButton(
                icon: Icons.format_indent_increase,
                tooltip: 'Increase Indent',
                isActive: false,
                onPressed: indentLevel < 5
                    ? () => _changeIndent(indentLevel, 1)
                    : null,
                isDark: isDark,
              ),

              _divider(isDark),

              // --- Block quote ---
              _FormatButton(
                icon: Icons.format_quote,
                tooltip: 'Block Quote',
                isActive: isBlockQuote,
                onPressed: () => _toggleBlock(Attribute.blockQuote, style),
                isDark: isDark,
              ),

              _divider(isDark),

              // --- Clear formatting ---
              _FormatButton(
                icon: Icons.format_clear,
                tooltip: 'Clear Formatting',
                isActive: false,
                onPressed: () => _clearFormatting(),
                isDark: isDark,
              ),

              const Spacer(),

              Text(
                'Rich Text',
                style: TextStyle(
                  fontSize: 11,
                  color: isDark ? const Color(0xFF606060) : const Color(0xFFAAAAAA),
                  fontStyle: FontStyle.italic,
                ),
              ),
              const SizedBox(width: 4),
            ],
          );
        },
      ),
    );
  }

  void _toggleInline(Attribute attr) {
    final style = controller.getSelectionStyle();
    if (style.containsKey(attr.key)) {
      controller.formatSelection(Attribute.clone(attr, null));
    } else {
      controller.formatSelection(attr);
    }
  }

  void _toggleBlock(Attribute attr, Style style) {
    if (style.containsKey(attr.key)) {
      controller.formatSelection(Attribute.clone(attr, null));
    } else {
      controller.formatSelection(attr);
    }
  }

  void _setHeading(int level) {
    if (level == 0) {
      controller.formatSelection(Attribute.clone(Attribute.header, null));
    } else {
      controller.formatSelection(Attribute.clone(Attribute.header, level));
    }
  }

  void _setAlignment(String? align) {
    controller.formatSelection(Attribute.clone(Attribute.align, align));
  }

  void _changeIndent(int current, int delta) {
    final newLevel = current + delta;
    if (newLevel <= 0) {
      controller.formatSelection(Attribute.clone(Attribute.indent, null));
    } else {
      controller.formatSelection(Attribute.clone(Attribute.indent, newLevel));
    }
  }

  void _clearFormatting() {
    // Inline formatting
    controller.formatSelection(Attribute.clone(Attribute.bold, null));
    controller.formatSelection(Attribute.clone(Attribute.italic, null));
    controller.formatSelection(Attribute.clone(Attribute.underline, null));
    controller.formatSelection(Attribute.clone(Attribute.strikeThrough, null));
    controller.formatSelection(const ColorAttribute(null));
    controller.formatSelection(const BackgroundAttribute(null));
    // Font & size
    controller.formatSelection(Attribute.clone(Attribute.font, null));
    controller.formatSelection(Attribute.clone(Attribute.size, null));
    // Block-level formatting
    controller.formatSelection(Attribute.clone(Attribute.header, null));
    controller.formatSelection(Attribute.clone(Attribute.align, null));
  }

  Widget _divider(bool isDark) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 7),
      child: Container(
        width: 1,
        color: isDark ? const Color(0xFF2A2A2A) : const Color(0xFFE0E0E0),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Heading dropdown
// ---------------------------------------------------------------------------

class _HeadingDropdown extends StatelessWidget {
  final int headerLevel;
  final bool isDark;
  final ValueChanged<int> onSelected;

  const _HeadingDropdown({
    required this.headerLevel,
    required this.isDark,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final activeColor = Theme.of(context).colorScheme.primary;
    final color = isDark ? const Color(0xFFB0B0B0) : const Color(0xFF555555);
    final isActive = headerLevel > 0;
    final label = headerLevel == 0 ? 'Normal' : 'Heading $headerLevel';

    return PopupMenuButton<int>(
      tooltip: 'Paragraph Style',
      offset: const Offset(0, 38),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
      itemBuilder: (ctx) => [
        PopupMenuItem(value: 0, height: 36, child: Text('Normal',
          style: TextStyle(fontSize: 13, color: headerLevel == 0 ? activeColor : null))),
        PopupMenuItem(value: 1, height: 40, child: Text('Heading 1',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: headerLevel == 1 ? activeColor : null))),
        PopupMenuItem(value: 2, height: 38, child: Text('Heading 2',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: headerLevel == 2 ? activeColor : null))),
        PopupMenuItem(value: 3, height: 36, child: Text('Heading 3',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: headerLevel == 3 ? activeColor : null))),
      ],
      onSelected: onSelected,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: isActive ? activeColor.withValues(alpha: 0.1) : null,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: TextStyle(
              fontSize: 12,
              fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
              color: isActive ? activeColor : color,
            )),
            const SizedBox(width: 2),
            Icon(Icons.arrow_drop_down, size: 16, color: isActive ? activeColor : color),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Font family dropdown
// ---------------------------------------------------------------------------

class _FontFamilyDropdown extends StatelessWidget {
  final String? currentFont;
  final bool isDark;
  final ValueChanged<String?> onSelected;

  const _FontFamilyDropdown({
    required this.currentFont,
    required this.isDark,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final color = isDark ? const Color(0xFFB0B0B0) : const Color(0xFF555555);
    final label = currentFont ?? 'Calibri';

    return PopupMenuButton<String?>(
      tooltip: 'Font Family',
      offset: const Offset(0, 38),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
      constraints: const BoxConstraints(maxHeight: 400),
      onSelected: onSelected,
      itemBuilder: (ctx) => [
        PopupMenuItem<String?>(
          value: null,
          height: 30,
          child: Text('Default', style: TextStyle(
            fontSize: 12,
            fontStyle: FontStyle.italic,
            color: currentFont == null
                ? Theme.of(ctx).colorScheme.primary
                : color,
          )),
        ),
        const PopupMenuDivider(height: 1),
        ...systemFonts.map((font) => PopupMenuItem<String?>(
          value: font,
          height: 30,
          child: Text(font, style: TextStyle(
            fontFamily: font,
            fontSize: 13,
            color: font == currentFont
                ? Theme.of(ctx).colorScheme.primary
                : null,
          )),
        )),
      ],
      child: Container(
        width: 100,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: isDark ? const Color(0xFF3A3A3A) : const Color(0xFFCCCCCC),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: color),
              ),
            ),
            Icon(Icons.arrow_drop_down, size: 14, color: color),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Font size dropdown
// ---------------------------------------------------------------------------

class _FontSizeDropdown extends StatelessWidget {
  final int? currentSize;
  final bool isDark;
  final ValueChanged<int?> onSelected;

  const _FontSizeDropdown({
    required this.currentSize,
    required this.isDark,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final color = isDark ? const Color(0xFFB0B0B0) : const Color(0xFF555555);
    final label = currentSize?.toString() ?? '14';

    return PopupMenuButton<int?>(
      tooltip: 'Font Size',
      offset: const Offset(0, 38),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
      constraints: const BoxConstraints(maxHeight: 400),
      onSelected: onSelected,
      itemBuilder: (ctx) => [
        PopupMenuItem<int?>(
          value: null,
          height: 28,
          child: Text('Default', style: TextStyle(
            fontSize: 12,
            fontStyle: FontStyle.italic,
            color: currentSize == null
                ? Theme.of(ctx).colorScheme.primary
                : color,
          )),
        ),
        const PopupMenuDivider(height: 1),
        ...fontSizes.map((size) => PopupMenuItem<int?>(
          value: size,
          height: 28,
          child: Text('$size', style: TextStyle(
            fontSize: 13,
            color: size == currentSize
                ? Theme.of(ctx).colorScheme.primary
                : null,
          )),
        )),
      ],
      child: Container(
        width: 44,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: isDark ? const Color(0xFF3A3A3A) : const Color(0xFFCCCCCC),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: color),
              ),
            ),
            Icon(Icons.arrow_drop_down, size: 14, color: color),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Color picker button + grid popup
// ---------------------------------------------------------------------------

/// A toolbar button that opens a color picker popup.
/// Shows the icon with a colored indicator bar underneath.
class _ColorPickerButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final List<Color> colors;
  final List<String> colorNames;
  final String? currentHex;
  final bool isDark;
  final ValueChanged<String?> onColorSelected;

  const _ColorPickerButton({
    required this.icon,
    required this.tooltip,
    required this.colors,
    required this.colorNames,
    this.currentHex,
    required this.isDark,
    required this.onColorSelected,
  });

  @override
  Widget build(BuildContext context) {
    final defaultColor = isDark ? const Color(0xFFB0B0B0) : const Color(0xFF555555);
    final mutedColor = isDark ? const Color(0xFF606060) : const Color(0xFFAAAAAA);
    final hasColor = currentHex != null;
    final barColor = hasColor ? _hexToColor(currentHex!) : mutedColor;

    return PopupMenuButton<String?>(
      tooltip: tooltip,
      offset: const Offset(0, 38),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
      constraints: const BoxConstraints(minWidth: 220),
      onSelected: onColorSelected,
      itemBuilder: (ctx) => [
        // "Remove" option — use empty string as sentinel (null = popup dismissed)
        PopupMenuItem<String?>(
          value: '',
          height: 32,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.format_color_reset, size: 15,
                color: isDark ? const Color(0xFFB0B0B0) : const Color(0xFF555555)),
              const SizedBox(width: 8),
              Text('Remove', style: TextStyle(fontSize: 12,
                color: isDark ? const Color(0xFFB0B0B0) : const Color(0xFF555555))),
            ],
          ),
        ),
        const PopupMenuDivider(height: 1),
        // Color grid
        _ColorGridEntry(
          colors: colors,
          names: colorNames,
          selectedHex: currentHex,
          isDark: isDark,
        ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 3),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: hasColor ? barColor : defaultColor),
            const SizedBox(height: 1),
            Container(
              width: 16,
              height: 3,
              decoration: BoxDecoration(
                color: barColor,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static Color _hexToColor(String hex) {
    var cleaned = hex.replaceFirst('#', '');
    if (cleaned.length == 6) {
      return Color(int.parse('FF$cleaned', radix: 16));
    }
    if (cleaned.length == 8) {
      return Color(int.parse(cleaned, radix: 16));
    }
    return const Color(0xFFFFFFFF);
  }
}

/// Custom PopupMenuEntry that renders a grid of color circles.
class _ColorGridEntry extends PopupMenuEntry<String?> {
  final List<Color> colors;
  final List<String> names;
  final String? selectedHex;
  final bool isDark;

  const _ColorGridEntry({
    required this.colors,
    required this.names,
    this.selectedHex,
    required this.isDark,
  });

  @override
  double get height => 80;

  @override
  bool represents(String? value) => false;

  @override
  State<_ColorGridEntry> createState() => _ColorGridEntryState();
}

class _ColorGridEntryState extends State<_ColorGridEntry> {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: List.generate(widget.colors.length, (i) {
          final color = widget.colors[i];
          final hex = _colorToHex(color);
          final isSelected = hex.toLowerCase() == widget.selectedHex?.toLowerCase();
          final activeColor = Theme.of(context).colorScheme.primary;

          return Tooltip(
            message: widget.names[i],
            waitDuration: const Duration(milliseconds: 300),
            child: GestureDetector(
              onTap: () => Navigator.pop(context, hex),
              child: Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: isSelected
                      ? Border.all(color: activeColor, width: 2.5)
                      : Border.all(
                          color: widget.isDark
                              ? const Color(0xFF444444)
                              : const Color(0xFFDDDDDD),
                        ),
                  boxShadow: isSelected
                      ? [BoxShadow(
                          color: activeColor.withValues(alpha: 0.4),
                          blurRadius: 6,
                        )]
                      : null,
                ),
              ),
            ),
          );
        }),
      ),
    );
  }

  static String _colorToHex(Color c) {
    return '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
  }
}

// ---------------------------------------------------------------------------
// Generic formatting button
// ---------------------------------------------------------------------------

class _FormatButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final bool isActive;
  final VoidCallback? onPressed;
  final bool isDark;

  const _FormatButton({
    required this.icon,
    required this.tooltip,
    required this.isActive,
    required this.onPressed,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final isDisabled = onPressed == null;
    final activeColor = Theme.of(context).colorScheme.primary;
    final color = isDisabled
        ? (isDark ? const Color(0xFF404040) : const Color(0xFFCCCCCC))
        : isActive
            ? activeColor
            : (isDark ? const Color(0xFFB0B0B0) : const Color(0xFF555555));

    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(4),
        child: Container(
          padding: const EdgeInsets.all(5),
          decoration: isActive
              ? BoxDecoration(
                  color: activeColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(4),
                )
              : null,
          child: Icon(icon, size: 17, color: color),
        ),
      ),
    );
  }
}
