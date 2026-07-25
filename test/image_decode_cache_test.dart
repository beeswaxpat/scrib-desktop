import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrib_desktop/services/image_embed_service.dart';

/// The embed renderer must not re-run the base64 decode (and, downstream, the
/// full bitmap decode) every time an embed widget state is recreated: the LRU
/// returns the SAME bytes instance per data URI, which is what makes
/// MemoryImage hit Flutter's ImageCache across tab switches.
void main() {
  String uriFor(int n) =>
      'data:image/png;base64,${base64Encode(Uint8List.fromList(List.filled(8, n)))}';

  setUp(ImageEmbedService.clearDecodeCache);

  group('decodeDataUriCached', () {
    test('returns the identical bytes instance on repeat lookups', () {
      final a = ImageEmbedService.decodeDataUriCached(uriFor(1));
      final b = ImageEmbedService.decodeDataUriCached(uriFor(1));
      expect(a, isNotNull);
      expect(identical(a!.bytes, b!.bytes), isTrue);
      expect(a.mime, 'image/png');
    });

    test('is bounded: least-recently-used entry is evicted at capacity', () {
      final first = ImageEmbedService.decodeDataUriCached(uriFor(0))!;
      for (var i = 1; i <= ImageEmbedService.decodeCacheCapacity; i++) {
        ImageEmbedService.decodeDataUriCached(uriFor(i));
      }
      // uriFor(0) was the oldest entry and must have been evicted, so a new
      // lookup decodes fresh bytes (different instance, same content).
      final again = ImageEmbedService.decodeDataUriCached(uriFor(0))!;
      expect(identical(first.bytes, again.bytes), isFalse);
      expect(again.bytes, first.bytes);
    });

    test('recently-used entries survive new insertions', () {
      final zero = ImageEmbedService.decodeDataUriCached(uriFor(0))!;
      for (var i = 1; i < ImageEmbedService.decodeCacheCapacity; i++) {
        ImageEmbedService.decodeDataUriCached(uriFor(i));
      }
      // Touch 0 so it becomes most-recently-used, then push one more entry.
      ImageEmbedService.decodeDataUriCached(uriFor(0));
      ImageEmbedService.decodeDataUriCached(
          uriFor(ImageEmbedService.decodeCacheCapacity));
      final again = ImageEmbedService.decodeDataUriCached(uriFor(0))!;
      expect(identical(zero.bytes, again.bytes), isTrue);
    });

    test('an oversized payload is refused, so the LRU bound really holds', () {
      // The capacity comment claims ~32 MB (8 x maxEmbedBytes). That is only
      // true if the READ path refuses anything bigger, which it did not.
      final oversized = 'data:image/png;base64,'
          '${'A' * (ImageEmbedService.maxEmbedBase64Chars + 4)}';
      expect(ImageEmbedService.decodeDataUriCached(oversized), isNull);
      expect(ImageEmbedService.decodeDataUriCached(oversized), isNull);
    });

    test('invalid URIs return null and are not cached', () {
      expect(ImageEmbedService.decodeDataUriCached('nonsense'), isNull);
      expect(ImageEmbedService.decodeDataUriCached('data:image/png;base64'),
          isNull);
    });
  });

  group('displayCacheWidth', () {
    test('scales display width by device pixel ratio', () {
      expect(ImageEmbedService.displayCacheWidth(420, 1.0), 420);
      expect(ImageEmbedService.displayCacheWidth(360, 2.0), 720);
      expect(ImageEmbedService.displayCacheWidth(420, 1.25), 525);
    });

    test('clamps the decode target and survives a zero ratio', () {
      expect(ImageEmbedService.displayCacheWidth(1000, 3.0), 2400);
      expect(ImageEmbedService.displayCacheWidth(0, 2.0), 1);
      expect(ImageEmbedService.displayCacheWidth(100, 0), 100);
    });
  });
}
