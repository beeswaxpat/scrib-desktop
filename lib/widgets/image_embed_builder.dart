import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../services/image_embed_service.dart';

/// Picks an image and inserts it as a block embed at the controller's current
/// selection. Returns a user-facing error message, or null on success/cancel.
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

/// Renders Quill `image` embeds whose source is a base64 `data:` URI. SVG sources
/// render as vectors; every other format renders via [Image.memory]. The image
/// is left-aligned, constrained, and scaled down to fit the editor.
class ScribImageEmbedBuilder extends EmbedBuilder {
  const ScribImageEmbedBuilder();

  @override
  String get key => BlockEmbed.imageType; // 'image'

  @override
  Widget build(BuildContext context, EmbedContext embedContext) {
    final source = embedContext.node.value.data;
    final decoded =
        source is String ? ImageEmbedService.decodeDataUri(source) : null;

    if (decoded == null) return _broken(context);

    final Widget image = decoded.mime == 'image/svg+xml'
        ? SvgPicture.memory(
            decoded.bytes,
            fit: BoxFit.scaleDown,
            placeholderBuilder: (_) => _broken(context),
          )
        : Image.memory(
            decoded.bytes,
            fit: BoxFit.scaleDown,
            errorBuilder: (_, _, _) => _broken(context),
          );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640, maxHeight: 480),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: image,
          ),
        ),
      ),
    );
  }

  Widget _broken(BuildContext context) {
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
