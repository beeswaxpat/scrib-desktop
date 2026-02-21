import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:provider/provider.dart';
import '../providers/editor_provider.dart';
import '../services/settings_service.dart';
import '../constants.dart';

/// The main editing area - supports both plain text and rich text modes
class ScribEditor extends StatefulWidget {
  const ScribEditor({super.key});

  @override
  State<ScribEditor> createState() => ScribEditorState();
}

class ScribEditorState extends State<ScribEditor> {
  final _editorScrollController = ScrollController();
  final _lineNumberScrollController = ScrollController();

  // Rich text state
  QuillController? _quillController;
  final _quillFocusNode = FocusNode();
  final _quillScrollController = ScrollController();
  int? _lastTabIndex;
  EditorMode? _lastMode;

  @override
  void initState() {
    super.initState();
    _editorScrollController.addListener(_syncLineNumbers);
  }

  @override
  void dispose() {
    _editorScrollController.removeListener(_syncLineNumbers);
    _editorScrollController.dispose();
    _lineNumberScrollController.dispose();
    _quillController?.dispose();
    _quillFocusNode.dispose();
    _quillScrollController.dispose();
    super.dispose();
  }

  void _syncLineNumbers() {
    if (_lineNumberScrollController.hasClients) {
      _lineNumberScrollController.jumpTo(_editorScrollController.offset);
    }
  }

  /// Get the current QuillController (for formatting toolbar)
  QuillController? get quillController => _quillController;

  /// Rebuild the QuillController when tab or mode changes
  void _ensureQuillController(EditorTab tab, int tabIndex) {
    final needsRebuild = _lastTabIndex != tabIndex ||
        _lastMode != tab.mode ||
        (tab.mode == EditorMode.richText && _quillController == null);

    if (!needsRebuild) return;

    _lastTabIndex = tabIndex;
    _lastMode = tab.mode;

    // Detach and defer disposal of old controller to avoid blocking the frame
    final old = _quillController;
    if (old != null) {
      old.removeListener(_onQuillChanged);
      _quillController = null;
      Future.microtask(() => old.dispose());
    }

    if (tab.mode == EditorMode.richText) {
      try {
        Document doc;
        if (tab.deltaJson.isNotEmpty) {
          final ops = jsonDecode(tab.deltaJson) as List<dynamic>;
          doc = Document.fromJson(ops);
        } else {
          doc = Document()..insert(0, '');
        }
        _quillController = QuillController(
          document: doc,
          selection: const TextSelection.collapsed(offset: 0),
        );
        _quillController!.addListener(_onQuillChanged);
      } catch (_) {
        // Fallback to empty doc if delta parsing fails
        _quillController = QuillController.basic();
        _quillController!.addListener(_onQuillChanged);
      }
    }
  }

  void _onQuillChanged() {
    if (_quillController == null) return;
    final editor = context.read<EditorProvider>();
    final deltaJson = jsonEncode(_quillController!.document.toDelta().toJson());
    editor.updateDeltaJson(deltaJson);
  }

  @override
  Widget build(BuildContext context) {
    // Targeted selects — only rebuild when these specific values change.
    // activeTabIndex + mode cover all tab-switch and mode-switch scenarios.
    final tabIndex = context.select<EditorProvider, int>((e) => e.activeTabIndex);
    final mode = context.select<EditorProvider, EditorMode?>((e) => e.activeTab?.mode);
    final colorIndex = context.select<EditorProvider, int?>((e) => e.activeTab?.colorIndex);
    final tabFontFamily = context.select<EditorProvider, String>((e) => e.activeTab?.tabFontFamily ?? 'Calibri');
    final tabFontSize = context.select<EditorProvider, double>((e) => e.activeTab?.tabFontSize ?? 14.0);
    final showLineNumbers = context.select<SettingsService, bool>((s) => s.showLineNumbers);

    final editor = context.read<EditorProvider>();
    final tab = editor.activeTab;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (tab == null) {
      return _buildEmptyState(context);
    }

    // Rebuild QuillController if needed
    _ensureQuillController(tab, tabIndex);

    // Color border when tab has a per-tab color assigned
    final borderColor = colorIndex != null
        ? accentColors[colorIndex.clamp(0, accentColors.length - 1)]
        : null;

    return RepaintBoundary(
      child: Container(
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF0D0D0D) : Colors.white,
          border: borderColor != null ? Border.all(color: borderColor, width: 2) : null,
        ),
        child: mode == EditorMode.richText
            ? _buildRichTextEditor(tab, isDark)
            : _buildPlainTextEditor(tab, editor, tabFontFamily, tabFontSize, showLineNumbers, isDark),
      ),
    );
  }

  Widget _buildPlainTextEditor(
    EditorTab tab,
    EditorProvider editor,
    String fontFamily,
    double fontSize,
    bool showLineNumbers,
    bool isDark,
  ) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showLineNumbers)
          _LineNumberGutter(
            lineCount: editor.lineCount,
            fontSize: fontSize,
            fontFamily: fontFamily,
            isDark: isDark,
            scrollController: _lineNumberScrollController,
          ),
        Expanded(
          child: TextField(
            controller: tab.controller,
            undoController: tab.undoController,
            scrollController: _editorScrollController,
            maxLines: null,
            expands: true,
            textAlignVertical: TextAlignVertical.top,
            style: TextStyle(
              fontFamily: fontFamily,
              fontSize: fontSize,
              color: isDark ? const Color(0xFFE0E0E0) : const Color(0xFF1A1A1A),
              height: 1.6,
            ),
            decoration: const InputDecoration(
              contentPadding: EdgeInsets.all(16),
              border: InputBorder.none,
              focusedBorder: InputBorder.none,
            ),
            cursorColor: Theme.of(context).colorScheme.primary,
            onChanged: (_) => editor.onContentChanged(),
          ),
        ),
      ],
    );
  }

  Widget _buildRichTextEditor(EditorTab tab, bool isDark) {
    if (_quillController == null) {
      return const Center(child: CircularProgressIndicator());
    }

    // Rich text paragraph base style uses a fixed default — NOT tabFontFamily/tabFontSize.
    // In rich text mode, font and size are controlled exclusively through the formatting
    // toolbar (inline Quill Delta attributes stored in the document). Passing tabFontFamily/
    // tabFontSize here would cause the QuillEditor to rebuild and shift rendering every time
    // the user triggered View > Text Size or switched plain-text font settings, interfering
    // with any inline formatting they explicitly set via the formatting toolbar.
    const richTextDefaultFontFamily = 'Calibri';
    const richTextDefaultFontSize = 14.0;

    return QuillEditor(
      controller: _quillController!,
      focusNode: _quillFocusNode,
      scrollController: _quillScrollController,
      config: QuillEditorConfig(
        placeholder: 'Start typing...',
        padding: const EdgeInsets.all(16),
        customStyles: DefaultStyles(
          paragraph: DefaultTextBlockStyle(
            TextStyle(
              fontFamily: richTextDefaultFontFamily,
              fontSize: richTextDefaultFontSize,
              color: isDark ? const Color(0xFFE0E0E0) : const Color(0xFF1A1A1A),
              height: 1.6,
            ),
            const HorizontalSpacing(0, 0),
            const VerticalSpacing(0, 0),
            const VerticalSpacing(0, 0),
            null,
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      color: isDark ? const Color(0xFF0D0D0D) : Colors.white,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.edit_note,
              size: 48,
              color: colorScheme.primary.withValues(alpha: 0.3),
            ),
            const SizedBox(height: 16),
            Text(
              'No tracking. No cloud. Just notes.',
              style: TextStyle(
                color: isDark ? const Color(0xFF606060) : const Color(0xFFAAAAAA),
                fontSize: 14,
                fontStyle: FontStyle.italic,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Ctrl+N to create  |  Ctrl+O to open  |  Drop a file here',
              style: TextStyle(
                color: isDark ? const Color(0xFF404040) : const Color(0xFFCCCCCC),
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Line number gutter widget with lazy rendering and scroll sync
class _LineNumberGutter extends StatelessWidget {
  final int lineCount;
  final double fontSize;
  final String fontFamily;
  final bool isDark;
  final ScrollController scrollController;

  const _LineNumberGutter({
    required this.lineCount,
    required this.fontSize,
    required this.fontFamily,
    required this.isDark,
    required this.scrollController,
  });

  @override
  Widget build(BuildContext context) {
    final digits = lineCount.toString().length;
    final gutterWidth = (digits * fontSize * 0.65) + 24;
    final lineHeight = fontSize * 1.6;

    return Container(
      width: gutterWidth,
      color: isDark ? const Color(0xFF111111) : const Color(0xFFF5F5F5),
      child: ListView.builder(
        controller: scrollController,
        padding: const EdgeInsets.only(top: 16, right: 8),
        physics: const NeverScrollableScrollPhysics(),
        itemCount: lineCount,
        itemExtent: lineHeight,
        itemBuilder: (context, i) => Align(
          alignment: Alignment.centerRight,
          child: Text(
            '${i + 1}',
            textAlign: TextAlign.right,
            style: TextStyle(
              fontFamily: fontFamily,
              fontSize: fontSize,
              color: isDark ? const Color(0xFF404040) : const Color(0xFFCCCCCC),
              height: 1.6,
            ),
          ),
        ),
      ),
    );
  }
}
