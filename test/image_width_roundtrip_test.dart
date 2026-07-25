import 'dart:convert';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:scrib_desktop/services/image_embed_service.dart';

/// Image resizing stores a `width` attribute on the image embed via
/// `controller.formatText`. This verifies that attribute is applied and that it
/// survives the delta round-trip that gets encrypted into a .scrb, so a resized
/// image keeps its size after save/reopen.
void main() {
  test('image width attribute applies and round-trips', () {
    const uri = 'data:image/png;base64,AAAA';
    final doc = Document()..insert(0, BlockEmbed.image(uri));
    final controller = QuillController(
      document: doc,
      selection: const TextSelection.collapsed(offset: 0),
    );

    // Mirrors the resize path in the image embed builder: width is stored in
    // the embed's CSS `style` attribute (the only image attribute Quill's
    // format rules accept).
    controller.formatText(0, 1, StyleAttribute('width: 320px;'));

    final json = jsonEncode(controller.document.toDelta().toJson());
    final reopened = Document.fromJson(jsonDecode(json) as List<dynamic>);

    String? styleValue;
    var sawImage = false;
    for (final op in reopened.toDelta().toList()) {
      final data = op.data;
      if (data is Map && data.containsKey('image')) {
        sawImage = true;
        styleValue = op.attributes?['style']?.toString();
      }
    }

    expect(sawImage, true, reason: 'image embed should survive round-trip');
    expect(styleValue, isNotNull, reason: 'style should persist on the embed');
    expect(styleValue, contains('width: 320px'),
        reason: 'stored width should round-trip');
  });

  group('storedWidth', () {
    test('reads a normal stored width back unchanged', () {
      expect(ImageEmbedService.storedWidth('width: 320px;'), 320.0);
      expect(ImageEmbedService.storedWidth('width:320px'), 320.0);
    });

    test('clamps a crafted width instead of laying out at it', () {
      // The resize control clamps what it WRITES, but a hand-edited or crafted
      // style attribute carries any number, and it used to be honoured as-is.
      expect(ImageEmbedService.storedWidth('width: 999999px;'),
          ImageEmbedService.maxDisplayWidth);
      expect(ImageEmbedService.storedWidth('width: 0.5px;'),
          ImageEmbedService.minDisplayWidth);
    });

    test('returns null when there is no usable width', () {
      expect(ImageEmbedService.storedWidth(null), isNull);
      expect(ImageEmbedService.storedWidth('color: red;'), isNull);
      expect(ImageEmbedService.storedWidth('width: ...px;'), isNull);
    });
  });
}
