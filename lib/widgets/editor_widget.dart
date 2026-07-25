import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../providers/editor_provider.dart';
import '../dialogs/confirm_dialog.dart';
import '../services/format_utils.dart';
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
  final _plainFocusNode = FocusNode();

  // Keyed by tab IDENTITY, never by index: closing the active tab promotes its
  // successor to the SAME index, and the replace-empty-untitled open paths swap
  // a new tab in at index 0. An index-keyed cache kept the closed tab's
  // controller alive in those cases, showing stale content and routing edits
  // into the wrong tab.
  EditorTab? _lastTab;
  EditorMode? _lastMode;

  /// The tab the live QuillController's Document was built from. _onQuillChanged
  /// refuses to write when the provider's active tab is a different object, so a
  /// controller that outlives its tab can never corrupt another tab's content.
  EditorTab? _quillTab;

  /// Subscription on the live controller's document change stream. The
  /// controller itself also notifies on selection-only changes (every caret
  /// move and click), and each notification used to re-serialize the whole
  /// document just for updateDeltaJson to discard it as identical. Document
  /// changes are the only events that can alter the serialized JSON, so this
  /// is the narrowest signal that keeps tab.deltaJson current.
  StreamSubscription<DocChange>? _docChangesSub;

  // Deferred build: the (tab, mode) we have actually committed to building.
  // Rich-text editors are heavy to lay out, so we paint a one-frame placeholder
  // first (letting a tab close / switch show immediately) then build the real
  // editor on the next frame.
  EditorTab? _builtTab;
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
    _docChangesSub?.cancel();
    _quillController?.dispose();
    _quillFocusNode.dispose();
    _quillScrollController.dispose();
    _plainFocusNode.dispose();
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
    _docChangesSub?.cancel();
    _docChangesSub = null;
    _quillController = null;
    _quillTab = null;
    Future.microtask(() => old.dispose());
    _publishQuillController();
  }

  /// Rebuild the QuillController when the active tab object or mode changes
  void _ensureQuillController(EditorTab tab) {
    final needsRebuild = !identical(_lastTab, tab) ||
        _lastMode != tab.mode ||
        (tab.mode == EditorMode.richText && _quillController == null);

    if (!needsRebuild) return;

    _lastTab = tab;
    _lastMode = tab.mode;

    final old = _quillController;
    if (old != null) {
      _docChangesSub?.cancel();
      _docChangesSub = null;
      _quillController = null;
      Future.microtask(() => old.dispose());
    }
    _quillTab = null;

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
      } catch (_) {
        // Fallback to empty doc if delta parsing fails
        _quillController = QuillController.basic();
      }
      _docChangesSub =
          _quillController!.document.changes.listen((_) => _onQuillChanged());
      _quillTab = tab;
    }

    _publishQuillController();
  }

  void _onQuillChanged() {
    final controller = _quillController;
    final sourceTab = _quillTab;
    if (controller == null || sourceTab == null) return;
    final editor = context.read<EditorProvider>();
    // Identity guard: if this controller's tab is no longer the active tab
    // (tab closed or switched while the old controller is still listened-to,
    // e.g. during the one-frame deferred-build placeholder), dropping the
    // change is the only safe option — updateDeltaJson writes to whatever tab
    // is active NOW, which would inject this document into a different note.
    if (!identical(editor.activeTab, sourceTab)) return;
    final deltaJson = jsonEncode(controller.document.toDelta().toJson());
    editor.updateDeltaJson(deltaJson);
  }

  /// Move the caret to the start of [line] (1-based) in the active plain-text
  /// tab and scroll it into view. No-op for rich-text or locked tabs.
  void goToLine(int line) {
    final editor = context.read<EditorProvider>();
    final tab = editor.activeTab;
    if (tab == null || tab.isLocked || tab.mode != EditorMode.plainText) return;

    final text = tab.controller.text;
    int targetLine = 1;
    int offset = 0;
    while (targetLine < line) {
      final next = text.indexOf('\n', offset);
      if (next == -1) break; // past the last line: clamp to the last one
      offset = next + 1;
      targetLine++;
    }

    tab.controller.selection = TextSelection.collapsed(offset: offset);
    _plainFocusNode.requestFocus();
    if (_editorScrollController.hasClients) {
      final lineHeight = tab.tabFontSize * editorLineHeight;
      final target = ((targetLine - 1) * lineHeight)
          .clamp(0.0, _editorScrollController.position.maxScrollExtent);
      _editorScrollController.jumpTo(target);
    }
  }

  @override
  Widget build(BuildContext context) {
    // EditorTab does not override ==, so this select fires whenever the active
    // tab OBJECT changes — including a close that promotes the successor to
    // the same index, which an activeTabIndex select never sees.
    final tab = context.select<EditorProvider, EditorTab?>((e) => e.activeTab);
    final mode = context.select<EditorProvider, EditorMode?>((e) => e.activeTab?.mode);
    final colorIndex = context.select<EditorProvider, int?>((e) => e.activeTab?.colorIndex);
    final tabFontFamily = context.select<EditorProvider, String>((e) => e.activeTab?.tabFontFamily ?? 'Calibri');
    final tabFontSize = context.select<EditorProvider, double>((e) => e.activeTab?.tabFontSize ?? 14.0);
    final showLineNumbers = context.select<SettingsService, bool>((s) => s.showLineNumbers);

    final editor = context.read<EditorProvider>();
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final isLocked = context.select<EditorProvider, bool>(
        (e) => e.activeTab?.isLocked ?? false);

    if (tab == null) {
      _builtTab = null;
      _builtMode = null;
      return _buildEmptyState(context);
    }

    // A locked tab renders a lock screen instead of an editor. Tear down any
    // live QuillController so no decrypted document object outlives the lock,
    // and reset the build tracking so unlocking rebuilds from scratch.
    if (isLocked) {
      _teardownQuillController();
      _lastTab = null;
      _lastMode = null;
      _builtTab = null;
      _builtMode = null;
      return _editorSurface(colorIndex, isDark, _buildLockedState(context, tab));
    }

    // Defer the heavy first layout of a rich-text editor by one frame so a tab
    // close / switch paints the chrome (and removes the old tab) immediately,
    // then fills in the content on the next frame. Plain text lays out cheaply
    // and builds inline, so the common case is unaffected.
    final activationChanged = !identical(_builtTab, tab) || _builtMode != mode;
    if (mode == EditorMode.richText && activationChanged) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          _builtTab = tab;
          _builtMode = mode;
        });
      });
      return _editorSurface(colorIndex, isDark, const SizedBox.expand());
    }
    _builtTab = tab;
    _builtMode = mode;

    _ensureQuillController(tab);

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
            focusNode: _plainFocusNode,
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
        // Ctrl+click opens a link. Scheme allowlist (http/https/mailto) —
        // a note must never be able to launch anything else.
        onLaunchUrl: (url) async {
          if (!isSafeLaunchUrl(url)) {
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('That link was blocked: only http, https and '
                      'mailto links can be opened.'),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            }
            return;
          }
          final uri = Uri.tryParse(url);
          if (uri == null) return;
          // Show the real destination before leaving the app. Link TEXT is
          // arbitrary and a note can arrive from anyone, so the visible label
          // is not evidence of where the link goes.
          if (!context.mounted) return;
          final go = await showScribConfirm(
            context,
            title: 'Open Link?',
            message: 'This link opens in your browser:\n\n$url',
            confirmLabel: 'Open',
          );
          if (!go) return;
          if (await canLaunchUrl(uri)) {
            await launchUrl(uri, mode: LaunchMode.externalApplication);
          }
        },
        embedBuilders: const [
          ScribImageEmbedBuilder(),
          ScribTableEmbedBuilder(),
        ],
        // A crafted (or future-version) .scrb can carry an embed type this
        // build has no builder for; without a fallback flutter_quill throws
        // during widget build and the whole note becomes an error box. Render
        // a placeholder chip instead so the rest of the note stays usable.
        unknownEmbedBuilder: const ScribUnknownEmbedBuilder(),
        // flutter_quill installs its own Shortcuts widget around the editor's
        // focus node, so its defaults sit CLOSER to the focus than
        // MainScreen's CallbackShortcuts and silently win while a rich-text
        // editor has focus. Every collision with a documented Scrib shortcut
        // is remapped to _BubbleToAppIntent, which has NO registered Action
        // anywhere: quill's ShortcutManager finds the intent (custom entries
        // are inserted before quill's defaults in the merged map, so they
        // match first), finds no action, and returns 'ignored' — the raw key
        // event keeps bubbling up the focus chain to MainScreen, so the
        // documented app behavior wins. (DoNothingAndStopPropagationTextIntent
        // does NOT work here: quill maps it to DoNothingAction(consumesKey:
        // false), whose toKeyEventResult is skipRemainingHandlers — that stops
        // the event before it ever reaches MainScreen.) Ctrl+Z/Y/B/I/U stay
        // with quill — its handling matches the Scrib documentation.
        customShortcuts: const {
          // Quill: strikethrough. Scrib: Save As.
          SingleActivator(LogicalKeyboardKey.keyS, control: true, shift: true):
              _BubbleToAppIntent(),
          // Quill: built-in search dialog. Scrib: find bar.
          SingleActivator(LogicalKeyboardKey.keyF, control: true):
              _BubbleToAppIntent(),
          // Quill: indent. Scrib: plain/rich mode toggle.
          SingleActivator(LogicalKeyboardKey.keyM, control: true):
              _BubbleToAppIntent(),
          // Quill: unrestricted link dialog. Scrib: link dialog with the
          // http/https/mailto allowlist enforced at store time.
          SingleActivator(LogicalKeyboardKey.keyK, control: true):
              _BubbleToAppIntent(),
          // Quill: raw image-embed insert (bypasses Scrib's picker). Scrib:
          // Go to Line.
          SingleActivator(LogicalKeyboardKey.keyG, control: true):
              _BubbleToAppIntent(),
          // Quill: header clear + H1..H6 (H4-H6 aren't even representable in
          // Scrib's heading dropdown). Scrib: default text size (Ctrl+0) and
          // go-to-tab 1..6 (Ctrl+1..8 jump to tabs, Ctrl+9 to the last tab).
          SingleActivator(LogicalKeyboardKey.digit0, control: true):
              _BubbleToAppIntent(),
          SingleActivator(LogicalKeyboardKey.digit1, control: true):
              _BubbleToAppIntent(),
          SingleActivator(LogicalKeyboardKey.digit2, control: true):
              _BubbleToAppIntent(),
          SingleActivator(LogicalKeyboardKey.digit3, control: true):
              _BubbleToAppIntent(),
          SingleActivator(LogicalKeyboardKey.digit4, control: true):
              _BubbleToAppIntent(),
          SingleActivator(LogicalKeyboardKey.digit5, control: true):
              _BubbleToAppIntent(),
          SingleActivator(LogicalKeyboardKey.digit6, control: true):
              _BubbleToAppIntent(),
          // Quill: hide selection toolbar. Scrib: close find / search bar.
          SingleActivator(LogicalKeyboardKey.escape): _BubbleToAppIntent(),
        },
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

/// Matched by quill's Shortcuts for activators that collide with documented
/// Scrib shortcuts. Deliberately has NO registered Action anywhere in the
/// tree, so the ShortcutManager returns KeyEventResult.ignored and the raw
/// key event keeps bubbling up the focus chain to MainScreen's
/// CallbackShortcuts, where the app-level binding runs.
class _BubbleToAppIntent extends Intent {
  const _BubbleToAppIntent();
}

/// Fallback builder for embed types this build cannot render. Documents Scrib
/// writes only ever contain 'image' and 'scrib-table' embeds, which keep their
/// dedicated builders; this only activates on content no current build can
/// produce (a crafted or future-version file), turning a render crash into a
/// visible placeholder.
class ScribUnknownEmbedBuilder extends EmbedBuilder {
  const ScribUnknownEmbedBuilder();

  // Never matched by type lookup — this builder is returned directly as the
  // unknownEmbedBuilder fallback.
  @override
  String get key => 'unknown';

  @override
  bool get expanded => false;

  @override
  WidgetSpan buildWidgetSpan(Widget widget) {
    return WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: widget,
    );
  }

  @override
  Widget build(BuildContext context, EmbedContext embedContext) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final muted = isDark ? const Color(0xFF808080) : const Color(0xFF999999);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1A1A1A) : const Color(0xFFF0F0F0),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: isDark ? const Color(0xFF3A3A3A) : const Color(0xFFCCCCCC),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.help_outline, size: 18, color: muted),
          const SizedBox(width: 8),
          Text('Unsupported content',
              style: TextStyle(fontSize: 12, color: muted)),
        ],
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
        // Bottom padding mirrors the TextField's contentPadding so both lists
        // reach identical extents at full scroll.
        padding: const EdgeInsets.only(top: 16, right: 8, bottom: 16),
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
