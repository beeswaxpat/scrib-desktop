import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scrib_desktop/services/file_service.dart';
import 'package:scrib_desktop/services/image_embed_service.dart';

/// Image-embed processing: format detection, normalization, downscaling, the
/// data-URI codec, and that an embedded image survives a .scrb round-trip.
void main() {
  group('buildDataUri', () {
    test('keeps a small PNG as image/png with original bytes', () {
      final png = Uint8List.fromList(img.encodePng(img.Image(width: 2, height: 2)));
      final uri = ImageEmbedService.buildDataUri(png, 'png');
      expect(uri, startsWith('data:image/png;base64,'));
      final decoded = ImageEmbedService.decodeDataUri(uri)!;
      expect(decoded.mime, 'image/png');
      expect(decoded.bytes, png);
    });

    test('treats .svg as a vector (image/svg+xml)', () {
      final svg = Uint8List.fromList(
          utf8.encode('<svg xmlns="http://www.w3.org/2000/svg"></svg>'));
      final uri = ImageEmbedService.buildDataUri(svg, 'svg');
      expect(uri, startsWith('data:image/svg+xml;base64,'));
      expect(ImageEmbedService.decodeDataUri(uri)!.bytes, svg);
    });

    test('detects SVG by content even with a wrong extension', () {
      final svg = Uint8List.fromList(utf8.encode('<svg></svg>'));
      final uri = ImageEmbedService.buildDataUri(svg, 'txt');
      expect(uri, startsWith('data:image/svg+xml;base64,'));
    });

    test('normalizes a long-tail format (TGA) to a renderable PNG', () {
      final tga = Uint8List.fromList(img.encodeTga(img.Image(width: 4, height: 4)));
      final uri = ImageEmbedService.buildDataUri(tga, 'tga');
      expect(uri, startsWith('data:image/png;base64,'));
      final out = ImageEmbedService.decodeDataUri(uri)!;
      expect(img.decodeImage(out.bytes), isNotNull);
    });

    test('downscales an oversized image to maxDimension on its longest side', () {
      final tga = Uint8List.fromList(
          img.encodeTga(img.Image(width: 3000, height: 100)));
      final uri = ImageEmbedService.buildDataUri(tga, 'tga');
      final decoded = img.decodeImage(ImageEmbedService.decodeDataUri(uri)!.bytes)!;
      expect(decoded.width, ImageEmbedService.maxDimension);
    });

    test('rejects an undecodable format', () {
      expect(
        () => ImageEmbedService.buildDataUri(
            Uint8List.fromList([0, 1, 2, 3, 4, 5]), 'xyz'),
        throwsA(isA<ImageEmbedException>()),
      );
    });

    test('rejects empty bytes', () {
      expect(
        () => ImageEmbedService.buildDataUri(Uint8List(0), 'png'),
        throwsA(isA<ImageEmbedException>()),
      );
    });
  });

  group('decodeDataUri', () {
    test('returns null for non-data strings', () {
      expect(ImageEmbedService.decodeDataUri('C:/x.png'), isNull);
      expect(ImageEmbedService.decodeDataUri('https://example.com/x.png'), isNull);
    });

    test('returns null for a malformed data URI', () {
      expect(ImageEmbedService.decodeDataUri('data:image/png;base64'), isNull);
    });
  });

  test('an image embed survives a .scrb encrypt/decrypt round-trip', () async {
    final tmp = await Directory.systemTemp.createTemp('scrib_img_');
    try {
      final fs = FileService();
      final delta = [
        {'insert': 'before\n'},
        {
          'insert': {'image': 'data:image/png;base64,AAAA'}
        },
        {'insert': 'after\n'},
      ];
      final content = '{"scrib_rich":${jsonEncode(delta)}}';
      final path = '${tmp.path}${Platform.pathSeparator}note.scrb';

      await fs.writeScrbFile(path, content, 'pw', iterations: 1000);
      final back = await fs.readScrbFile(path, 'pw');

      expect(back, content);
      final ops = (jsonDecode(back!) as Map<String, dynamic>)['scrib_rich'] as List;
      expect(ops[1]['insert']['image'], 'data:image/png;base64,AAAA');
    } finally {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    }
  });
}
