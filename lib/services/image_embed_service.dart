import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// Raised when a chosen image cannot be embedded. The message is user-facing.
class ImageEmbedException implements Exception {
  final String message;
  ImageEmbedException(this.message);
  @override
  String toString() => message;
}

/// Turns an image file into a self-contained base64 `data:` URI suitable for a
/// Quill image embed. The URI travels inside the note's Delta, so for a `.scrb`
/// it is encrypted alongside the text and nothing is left unencrypted on disk.
///
/// Format strategy:
/// - SVG stays a vector (`image/svg+xml`).
/// - Common raster formats Flutter renders directly (PNG, JPEG, GIF, WebP, BMP)
///   keep their original bytes, so animated GIF/WebP keep animating.
/// - Everything else the `image` package can decode (TIFF, TGA, ICO, PSD, PNM,
///   EXR, ...) is decoded, downscaled if oversized, and re-encoded to PNG/JPEG.
class ImageEmbedService {
  /// Ceiling on the embedded (post-processing) byte size. base64 inflates this
  /// by ~33%, and the whole Delta is re-serialized as the user edits, so keep
  /// it modest. Most images downscale well under this.
  static const int maxEmbedBytes = 4 * 1024 * 1024;

  /// Longest-side pixel limit; larger raster images are downscaled on insert.
  static const int maxDimension = 2000;

  /// Raster formats Flutter renders directly from bytes.
  static const Set<String> nativeExts = {
    'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'wbmp', 'dib',
  };

  /// Native formats that may be animated, so we never decode/resize them.
  static const Set<String> animatedExts = {'gif', 'webp'};

  /// Extensions offered in the picker. The `image` package covers the long tail;
  /// anything it cannot decode is rejected with a clear message.
  static const List<String> pickerExtensions = [
    'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'wbmp', 'dib',
    'svg',
    'tif', 'tiff', 'tga', 'ico', 'psd', 'pnm', 'ppm', 'pgm', 'pbm',
    'exr', 'pvr', 'pcx', 'pic', 'cur',
  ];

  static const String supportedDescription =
      'PNG, JPEG, GIF, WebP, BMP, SVG, TIFF, TGA, ICO, PSD, PNM, EXR and more';

  /// Opens a file picker and returns a base64 data URI for the chosen image, or
  /// null if the user cancelled. Throws [ImageEmbedException] on a format that
  /// cannot be decoded or an image that stays too large after downscaling.
  static Future<String?> pickImageDataUri() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: pickerExtensions,
      dialogTitle: 'Insert Image',
      withData: true,
    );
    if (result == null || result.files.isEmpty) return null;

    final file = result.files.first;
    final ext = (file.extension ?? '').toLowerCase();
    Uint8List? bytes = file.bytes;
    if (bytes == null && file.path != null) {
      bytes = await File(file.path!).readAsBytes();
    }
    if (bytes == null) {
      throw ImageEmbedException('Could not read the selected file.');
    }
    return buildDataUri(bytes, ext);
  }

  /// Pure transform: raw bytes (+ extension hint) to a `data:` URI.
  /// Exposed for testing.
  static String buildDataUri(Uint8List bytes, String ext) {
    if (bytes.isEmpty) throw ImageEmbedException('The selected file is empty.');
    final e = ext.toLowerCase();

    // SVG: keep as a vector.
    if (e == 'svg' || _looksLikeSvg(bytes)) {
      _checkSize(bytes.length);
      return _dataUri('image/svg+xml', bytes);
    }

    if (nativeExts.contains(e)) {
      // Animated formats can't be downscaled without losing frames; keep as-is.
      if (animatedExts.contains(e)) {
        _checkSize(bytes.length);
        return _dataUri(_mimeForExt(e), bytes);
      }
      // Static native format: keep the original bytes when already small enough,
      // otherwise decode and downscale.
      if (bytes.length <= maxEmbedBytes) {
        return _dataUri(_mimeForExt(e), bytes);
      }
      final decoded = img.decodeImage(bytes);
      if (decoded == null) {
        throw ImageEmbedException(
            'Could not read this image. Try a smaller file.');
      }
      final norm = _encodeNormalized(decoded);
      return _dataUri(norm.mime, norm.bytes);
    }

    // Long-tail formats: decode with the image package, normalize to PNG/JPEG.
    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      throw ImageEmbedException(
          'Unsupported image format. Supported: $supportedDescription.');
    }
    final norm = _encodeNormalized(decoded);
    return _dataUri(norm.mime, norm.bytes);
  }

  static ({String mime, Uint8List bytes}) _encodeNormalized(img.Image image) {
    var out = image;
    final longest = image.width > image.height ? image.width : image.height;
    if (longest > maxDimension) {
      out = image.width >= image.height
          ? img.copyResize(image, width: maxDimension)
          : img.copyResize(image, height: maxDimension);
    }

    final png = img.encodePng(out);
    if (png.length <= maxEmbedBytes) {
      return (mime: 'image/png', bytes: png);
    }
    // PNG of a large photo can exceed the cap; JPEG is far smaller.
    final jpg = img.encodeJpg(out, quality: 85);
    if (jpg.length <= maxEmbedBytes) {
      return (mime: 'image/jpeg', bytes: jpg);
    }
    throw ImageEmbedException(
        'Image is too large to embed even after downscaling. '
        'Try a smaller image.');
  }

  static void _checkSize(int len) {
    if (len > maxEmbedBytes) {
      final mb = (maxEmbedBytes / (1024 * 1024)).toStringAsFixed(0);
      throw ImageEmbedException(
          'Image is larger than $mb MB and cannot be downscaled without losing '
          'quality (animated or vector). Use a smaller file.');
    }
  }

  static String _dataUri(String mime, Uint8List bytes) =>
      'data:$mime;base64,${base64Encode(bytes)}';

  static bool _looksLikeSvg(Uint8List bytes) {
    final head =
        String.fromCharCodes(bytes.take(256)).trimLeft().toLowerCase();
    return head.startsWith('<svg') ||
        (head.startsWith('<?xml') && head.contains('<svg'));
  }

  static String _mimeForExt(String ext) {
    switch (ext) {
      case 'png':
        return 'image/png';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      case 'bmp':
      case 'dib':
        return 'image/bmp';
      case 'wbmp':
        return 'image/vnd.wap.wbmp';
      default:
        return 'image/png';
    }
  }

  // ── Decode cache (embed rendering) ─────────────────────────────────────────

  /// Max entries in the decoded-bytes LRU. Each entry is at most
  /// [maxEmbedBytes] raw bytes, so the cache is bounded at ~32 MB.
  static const int decodeCacheCapacity = 8;

  /// LRU of decoded data URIs, keyed by the URI string itself. Returning the
  /// SAME Uint8List instance across widget rebuilds matters: MemoryImage keys
  /// Flutter's ImageCache by bytes-object identity, so a stable instance means
  /// a tab switch re-uses the already-rasterized image instead of re-running
  /// the base64 decode AND the bitmap decode.
  static final LinkedHashMap<String, ({String mime, Uint8List bytes})>
      _decodeCache = LinkedHashMap();

  /// [decodeDataUri] with a small LRU so recreated embed widgets (tab switch,
  /// mode toggle, unlock) share one decoded byte buffer per unique image.
  static ({String mime, Uint8List bytes})? decodeDataUriCached(String source) {
    final hit = _decodeCache.remove(source);
    if (hit != null) {
      _decodeCache[source] = hit; // re-insert: mark most recently used
      return hit;
    }
    final decoded = decodeDataUri(source);
    if (decoded == null) return null;
    _decodeCache[source] = decoded;
    if (_decodeCache.length > decodeCacheCapacity) {
      _decodeCache.remove(_decodeCache.keys.first);
    }
    return decoded;
  }

  @visibleForTesting
  static void clearDecodeCache() => _decodeCache.clear();

  /// Decode target width in physical pixels for an embed displayed at
  /// [displayWidth] logical pixels. Clamped so a corrupt stored width can
  /// never ask the decoder for an absurd bitmap. Used as `cacheWidth` so a
  /// 6000px photo shown as a 360px thumbnail is decoded at thumbnail size,
  /// not at ~96 MB of native-resolution RGBA.
  static int displayCacheWidth(double displayWidth, double devicePixelRatio) {
    final dpr = devicePixelRatio <= 0 ? 1.0 : devicePixelRatio;
    return (displayWidth * dpr).round().clamp(1, 2400);
  }

  /// Decodes a `data:` URI into its MIME type and raw bytes. Returns null if the
  /// string is not a base64 data URI. Used by the embed renderer.
  static ({String mime, Uint8List bytes})? decodeDataUri(String source) {
    if (!source.startsWith('data:')) return null;
    final comma = source.indexOf(',');
    if (comma == -1) return null;
    final header = source.substring(5, comma); // e.g. image/png;base64
    if (!header.contains('base64')) return null;
    final mime = header.split(';').first;
    try {
      final bytes = base64Decode(source.substring(comma + 1));
      // An empty payload can never render; null routes the embed straight to
      // its fallback chip instead of caching zero bytes for Image.memory.
      if (bytes.isEmpty) return null;
      return (mime: mime, bytes: bytes);
    } catch (_) {
      return null;
    }
  }
}
