import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:provider/provider.dart';
import '../providers/editor_provider.dart';
import '../services/settings_service.dart';
import '../constants.dart';
import 'image_embed_builder.dart';
import 'table_embed_builder.dart';

/// The main editing area - supports both plain text and rich text modes
class ScribEditor extends StatefulWidget {
  /// Receives the active tab's QuillController whenever it changes (null in
  /// plain-text mode). Lets the formatting toolbar / find bar react without the
  /// old post-frame setState round-trip on MainScreen.
  final ValueNotifier<QuillController?>? activeQuillNotifier;

  /// Invoked when the user asks to unlock the active locked tab (lock-screen
  /// button). MainScreen owns the password prompt and decrypt flow.
  final VoidCallback? onUnlockRequested;

  const ScribEditor({super.key, this.activeQuillNotifier, this.onUnlockRequested});

  @override
  State<ScribEditor> createState() => ScribEditorState();
}

class ScribEditorState extends State<ScribEditor> {
  final _editorScrollController = ScrollController();
  final _lineNumberScrollController = ScrollController();

  QuillController? _quillController;
  final _quillFocusNode = FocusNode();
  final _quillScrollController = ScrollController();
  int? _lastTabIndex;
  EditorMode? _lastMode;

  // Deferred build: the (tabIndex, mode) we have actually committed to building.
  // Rich-text editors are heavy to lay out, so we paint a one-frame placeholder
  // first (letting a tab close / switch show immediately) then build the real
  // editor on the next frame.
  int? _builtIndex;
  EditorMode? _builtMode;

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

  /// Publish the active controller to the listenable after the current frame
  /// (setting it mid-build would mark already-built toolbar widgets dirty).
  void _publishQuillController() {
    final notifier = widget.activeQuillNotifier;
    if (notifier == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && notifier.value != _quillController) {
        notifier.value = _quillController;
      }
    });
  }

  /// Drop the live QuillController (used when the active tab locks). The
  /// dispose is deferred a microtask so anything still pointing at it this
  /// frame (toolbar buttons) is not holding a disposed controller.
  void _teardownQuillController() {
    final old = _quillController;
    if (old == null) return;
    old.removeListener(_onQuillChanged);
    _quillController = null;
    Future.microtask(() => old.dispose());
    _publishQuillController();
  }

  /// Rebuild the QuillController when tab or mode changes
  void _ensureQuillController(EditorTab tab, int tabIndex) {
    final needsRebuild = _lastTabIndex != tabIndex ||
        _lastMode != tab.mode ||
        (tab.mode == EditorMode.richText && _quillController == null);

    if (!needsRebuild) return;

    _lastTabIndex = tabIndex;
    _lastMode = tab.mode;

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

    _publishQuillController();
  }

  void _onQuillChanged() {
    if (_quillController == null) return;
    final editor = context.read<EditorProvider>();
    final deltaJson = jsonEncode(_quillController!.document.toDelta().toJson());
    editor.updateDeltaJson(deltaJson);
  }

  @override
  Widget build(BuildContext context) {
    final tabIndex = context.select<EditorProvider, int>((e) => e.activeTabIndex);
    final mode = context.select<EditorProvider, EditorMode?>((e) => e.activeTab?.mode);
    final colorIndex = context.select<EditorProvider, int?>((e) => e.activeTab?.colorIndex);
    final tabFontFamily = context.select<EditorProvider, String>((e) => e.activeTab?.tabFontFamily ?? 'Calibri');
    final tabFontSize = context.select<EditorProvider, double>((e) => e.activeTab?.tabFontSize ?? 14.0);
    final showLineNumbers = context.select<SettingsService, bool>((s) => s.showLineNumbers);

    final editor = context.read<EditorProvider>();
    final tab = editor.activeTab;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final isLocked = context.select<EditorProvider, bool>(
        (e) => e.activeTab?.isLocked ?? false);

    if (tab == null) {
      _builtIndex = null;
      _builtMode = null;
      return _buildEmptyState(context);
    }

    // A locked tab renders a lock screen instead of an editor. Tear down any
    // live QuillController so no decrypted document object outlives the lock,
    // and reset the build tracking so unlocking rebuilds from scratch.
    if (isLocked) {
      _teardownQuillController();
      _lastTabIndex = null;
      _lastMode = null;
      _builtIndex = null;
      _builtMode = null;
      return _editorSurface(colorIndex, isDark, _buildLockedState(context, tab));
    }

    // Defer the heavy first layout of a rich-text editor by one frame so a tab
    // close / switch paints the chrome (and removes the old tab) immediately,
    // then fills in the content on the next frame. Plain text lays out cheaply
    // and builds inline, so the common case is unaffected.
    final activationChanged = _builtIndex != tabIndex || _builtMode != mode;
    if (mode == EditorMode.richText && activationChanged) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          _builtIndex = tabIndex;
          _builtMode = mode;
        });
      });
      return _editorSurface(colorIndex, isDark, const SizedBox.expand());
    }
    _builtIndex = tabIndex;
    _builtMode = mode;

    _ensureQuillController(tab, tabIndex);

    return _editorSurface(
      colorIndex,
      isDark,
      mode == EditorMode.richText
          ? _buildRichTextEditor(tab, isDark)
          : _buildPlainTextEditor(tab, editor, tabFontFamily, tabFontSize, showLineNumbers, isDark),
    );
  }

  /// Editor background + accent border chrome shared by the real editor and the
  /// one-frame placeholder, so deferring a rich-text build does not flash.
  Widget _editorSurface(int? colorIndex, bool isDark, Widget child) {
    final borderColor = colorIndex != null
        ? accentColors[colorIndex.clamp(0, accentColors.length - 1)]
            .withValues(alpha: 0.45)
        : null;

    return RepaintBoundary(
      child: Container(
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF0D0D0D) : Colors.white,
          border: borderColor != null
              ? Border(
                  left: BorderSide(color: borderColor, width: 2),
                  right: BorderSide(color: borderColor, width: 2),
                  bottom: BorderSide(color: borderColor, width: 2),
                )
              : null,
        ),
        child: child,
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

    // Fixed defaults — rich text font/size is controlled via inline Delta attributes,
    // not the per-tab plain-text settings.
    const richTextDefaultFontFamily = 'Calibri';
    const richTextDefaultFontSize = 14.0;

    return QuillEditor(
      controller: _quillController!,
      focusNode: _quillFocusNode,
      scrollController: _quillScrollController,
      config: QuillEditorConfig(
        placeholder: 'Start typing...',
        padding: const EdgeInsets.all(16),
        embedBuilders: const [
          ScribImageEmbedBuilder(),
          ScribTableEmbedBuilder(),
        ],
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

  /// Lock screen shown in place of the editor for a locked tab. The content
  /// and password are not in memory at this point — only the file path and
  /// name are known.
  Widget _buildLockedState(BuildContext context, EditorTab tab) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFFFBBF24).withValues(alpha: 0.12),
              border: Border.all(
                color: const Color(0xFFFBBF24).withValues(alpha: 0.5),
              ),
            ),
            child: const Icon(Icons.lock, size: 32, color: Color(0xFFFBBF24)),
          ),
          const SizedBox(height: 20),
          Text(
            tab.fileName,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w500,
              color: isDark ? const Color(0xFFE0E0E0) : const Color(0xFF1A1A1A),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'This note is locked. Its content and password are not in memory.',
            style: TextStyle(
              fontSize: 13,
              color: isDark ? const Color(0xFF808080) : const Color(0xFF666666),
            ),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            autofocus: true,
            onPressed: widget.onUnlockRequested,
            icon: const Icon(Icons.key, size: 18),
            label: const Text('Unlock'),
          ),
          const SizedBox(height: 8),
          Text(
            'Ctrl+L',
            style: TextStyle(
              fontSize: 11,
              color: isDark ? const Color(0xFF404040) : const Color(0xFFCCCCCC),
            ),
          ),
        ],
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
