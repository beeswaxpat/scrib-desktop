import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../services/image_embed_service.dart';

/// Picks an image and inserts it at the controller's current selection. Returns
/// a user-facing error message, or null on success/cancel.
Future<String?> pickAndInsertImage(QuillController controller) async {
  String? dataUri;
  try {
    dataUri = await ImageEmbedService.pickImageDataUri();
  } on ImageEmbedException catch (e) {
    return e.message;
  } catch (_) {
    return 'Could not insert image';
  }
  if (dataUri == null) return null; // cancelled

  final sel = controller.selection;
  final index = sel.isValid ? sel.start : 0;
  final length = sel.isValid ? sel.end - sel.start : 0;
  controller.replaceText(
    index,
    length,
    BlockEmbed.image(dataUri),
    TextSelection.collapsed(offset: index + 1),
  );
  return null;
}

/// Renders Quill `image` embeds (base64 `data:` URIs) as **inline** content so
/// text can sit beside an image on the same line (type to its left or right),
/// while pressing Enter puts text above or below it. Horizontal placement uses
/// the line's normal alignment (the Align buttons in the toolbar), so an image
/// moves like any other character rather than fighting a float layout.
///
/// Hovering an image reveals controls to resize it (stored as a `width`
/// attribute on the embed) or remove it.
class ScribImageEmbedBuilder extends EmbedBuilder {
  const ScribImageEmbedBuilder();

  @override
  String get key => BlockEmbed.imageType; // 'image'

  // Inline rendering: the image becomes part of the text line.
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
    final source = embedContext.node.value.data;
    if (source is! String) return _broken(context);

    return _ResizableImage(
      controller: embedContext.controller,
      node: embedContext.node,
      source: source,
      readOnly: embedContext.readOnly,
    );
  }

  static Widget _broken(BuildContext context) {
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
          Icon(Icons.broken_image_outlined, size: 18, color: muted),
          const SizedBox(width: 8),
          Text('Image unavailable',
              style: TextStyle(fontSize: 12, color: muted)),
        ],
      ),
    );
  }
}

class _ResizableImage extends StatefulWidget {
  final QuillController controller;
  final Embed node;
  final String source;
  final bool readOnly;

  const _ResizableImage({
    required this.controller,
    required this.node,
    required this.source,
    required this.readOnly,
  });

  @override
  State<_ResizableImage> createState() => _ResizableImageState();
}

class _ResizableImageState extends State<_ResizableImage> {
  static const double _minWidth = 80;
  static const double _maxWidth = 1000;
  static const double _defaultWidth = 360;
  static const double _step = 60;

  /// Display constraint when no width attribute is stored (matches the
  /// ConstrainedBox maxWidth), also the decode target for unsized embeds.
  static const double _defaultDisplayWidth = 420;

  bool _hovering = false;
  ({String mime, Uint8List bytes})? _decoded;
  String? _decodedSource;

  ({String mime, Uint8List bytes})? get _image {
    if (_decodedSource != widget.source) {
      // Cached: recreated embed states (tab switch, mode toggle, unlock) get
      // the SAME bytes instance back, so MemoryImage hits Flutter's ImageCache
      // instead of re-decoding the base64 and the bitmap.
      _decoded = ImageEmbedService.decodeDataUriCached(widget.source);
      _decodedSource = widget.source;
    }
    return _decoded;
  }

  static final _widthInStyle = RegExp(r'width:\s*([\d.]+)px');

  /// Width is stored in the embed's CSS `style` attribute (the only image
  /// attribute Quill's format rules accept), e.g. `width: 320px;`.
  double? _storedWidth() {
    final style = widget.node.style.attributes['style']?.value;
    if (style is! String) return null;
    final match = _widthInStyle.firstMatch(style);
    if (match == null) return null;
    return double.tryParse(match.group(1)!);
  }

  void _applyWidth(double w) {
    final clamped = w.clamp(_minWidth, _maxWidth);
    try {
      final off = widget.node.documentOffset;
      widget.controller.formatText(
        off,
        1,
        StyleAttribute('width: ${clamped.round()}px;'),
      );
    } catch (_) {
      // Node detached or shifted; ignore rather than crash the editor.
    }
  }

  void _resize(double delta) {
    final current = _storedWidth() ?? _defaultWidth;
    _applyWidth(current + delta);
  }

  void _delete() {
    try {
      final off = widget.node.documentOffset;
      widget.controller.replaceText(
        off,
        1,
        '',
        TextSelection.collapsed(offset: off),
      );
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final decoded = _image;
    if (decoded == null) return ScribImageEmbedBuilder._broken(context);

    final width = _storedWidth();

    final Widget image = decoded.mime == 'image/svg+xml'
        ? SvgPicture.memory(
            decoded.bytes,
            width: width,
            fit: width != null ? BoxFit.fitWidth : BoxFit.scaleDown,
            placeholderBuilder: (_) => ScribImageEmbedBuilder._broken(context),
          )
        : Image.memory(
            decoded.bytes,
            width: width,
            fit: width != null ? BoxFit.fitWidth : BoxFit.scaleDown,
            // Decode at display size (physical px), not native resolution.
            // ResizeImage never upscales, so small images stay untouched, and
            // a user resize changes the key so it re-decodes at the new size.
            cacheWidth: ImageEmbedService.displayCacheWidth(
              width ?? _defaultDisplayWidth,
              MediaQuery.devicePixelRatioOf(context),
            ),
            errorBuilder: (_, _, _) => ScribImageEmbedBuilder._broken(context),
          );

    final constrainedMaxWidth = width ?? _defaultDisplayWidth;

    final constrained = ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: constrainedMaxWidth,
        maxHeight: 600,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: image,
      ),
    );

    if (widget.readOnly) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 1),
        child: constrained,
      );
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 1),
        child: Stack(
          children: [
            constrained,
            if (_hovering)
              Positioned(
                top: 6,
                right: 6,
                child: _ImageControls(
                  onShrink: () => _resize(-_step),
                  onEnlarge: () => _resize(_step),
                  onDelete: _delete,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ImageControls extends StatelessWidget {
  final VoidCallback onShrink;
  final VoidCallback onEnlarge;
  final VoidCallback onDelete;

  const _ImageControls({
    required this.onShrink,
    required this.onEnlarge,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.62),
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _btn(Icons.remove, 'Smaller', onShrink),
            _btn(Icons.add, 'Larger', onEnlarge),
            _btn(Icons.delete_outline, 'Remove image', onDelete),
          ],
        ),
      ),
    );
  }

  Widget _btn(IconData icon, String tip, VoidCallback onTap) {
    return Tooltip(
      message: tip,
      waitDuration: const Duration(milliseconds: 400),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.all(5),
          child: Icon(icon, size: 16, color: Colors.white),
        ),
      ),
    );
  }
}
