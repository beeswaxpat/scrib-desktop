import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:image/image.dart' as img;
import 'package:scrib_desktop/providers/editor_provider.dart';
import 'package:scrib_desktop/services/file_operations.dart';
import 'package:scrib_desktop/services/file_service.dart';
import 'package:scrib_desktop/services/rtf_service.dart';
import 'package:scrib_desktop/services/settings_service.dart';

/// Images in .rtf: written as {\pict} groups on save and read back on open,
/// so a plain (unencrypted) file can keep a note's pictures.
void main() {
  img.Image picture(int w, int h) =>
      img.Image(width: w, height: h)..clear(img.ColorRgb8(200, 40, 90));

  String dataUri(String mime, Uint8List bytes) =>
      'data:$mime;base64,${base64Encode(bytes)}';

  final png = img.encodePng(picture(30, 20));
  final jpeg = img.encodeJpg(picture(40, 10));
  final gif = img.encodeGif(picture(12, 12));
  const svg = 'data:image/svg+xml;base64,PHN2Zz48L3N2Zz4=';

  String delta(List<Map<String, dynamic>> ops) => jsonEncode(ops);

  List<dynamic> ops(String rtf) => jsonDecode(RtfService.rtfToDelta(rtf));

  List<Map> images(String rtf) => [
        for (final op in ops(rtf))
          if (op['insert'] is Map) op as Map,
      ];

  String plainText(String rtf) => [
        for (final op in ops(rtf))
          if (op['insert'] is String) op['insert'] as String,
      ].join();

  group('export', () {
    test('a PNG is written as a pngblip picture with its size', () {
      final rtf = RtfService.deltaToRtf(delta([
        {'insert': 'Before\n'},
        {
          'insert': {'image': dataUri('image/png', png)},
          'attributes': {'style': 'width: 200px;'},
        },
        {'insert': '\nAfter\n'},
      ]));
      expect(rtf, contains(r'{\pict\pngblip\picw30\pich20'));
      expect(rtf, contains(r'\picwgoal3000\pichgoal2000'));
      expect(rtf, startsWith(r'{\rtf1'));
    });

    test('a JPEG is written as a jpegblip picture', () {
      final rtf = RtfService.deltaToRtf(delta([
        {'insert': {'image': dataUri('image/jpeg', jpeg)}},
        {'insert': '\n'},
      ]));
      expect(rtf, contains(r'\jpegblip\picw40\pich10'));
    });

    test('a GIF is converted to PNG', () {
      final rtf = RtfService.deltaToRtf(delta([
        {'insert': {'image': dataUri('image/gif', gif)}},
        {'insert': '\n'},
      ]));
      expect(rtf, contains(r'\pngblip\picw12\pich12'));
      final back = images(rtf).single['insert']['image'] as String;
      expect(back, startsWith('data:image/png;base64,'));
    });

    test('an SVG cannot be written and is reported', () {
      final d = delta([
        {'insert': {'image': svg}},
        {'insert': 'text\n'},
      ]);
      expect(RtfService.dropsEmbeds(d), isTrue);
      expect(RtfService.deltaToRtf(d), isNot(contains(r'\pict')));
    });

    test('dropsEmbeds: PNG/JPEG/GIF are kept; tables and broken images are not',
        () {
      String one(Object insert) => delta([
            {'insert': insert},
            {'insert': '\n'},
          ]);
      expect(RtfService.dropsEmbeds(one({'image': dataUri('image/png', png)})),
          isFalse);
      expect(
          RtfService.dropsEmbeds(one({'image': dataUri('image/jpeg', jpeg)})),
          isFalse);
      expect(RtfService.dropsEmbeds(one({'image': dataUri('image/gif', gif)})),
          isFalse);
      expect(RtfService.dropsEmbeds(one({'custom': '{"scrib-table":"{}"}'})),
          isTrue);
      expect(
          RtfService.dropsEmbeds(one({'image': 'data:image/png;base64,AAAA'})),
          isTrue);
      expect(RtfService.dropsEmbeds(one({'image': 'https://example.com/a.png'})),
          isTrue);
      expect(RtfService.dropsEmbeds(delta([{'insert': 'only text\n'}])),
          isFalse);
    });
  });

  group('round trip', () {
    test('PNG bytes, width and the text around it all come back', () {
      final rtf = RtfService.deltaToRtf(delta([
        {'insert': 'Before\n'},
        {
          'insert': {'image': dataUri('image/png', png)},
          'attributes': {'style': 'width: 200px;'},
        },
        {'insert': '\nAfter\n'},
      ]));
      final img0 = images(rtf).single;
      expect(img0['insert']['image'], dataUri('image/png', png));
      expect(img0['attributes'], {'style': 'width: 200px;'});
      expect(plainText(rtf), 'Before\n\nAfter\n');
    });

    test('JPEG bytes come back unchanged', () {
      final rtf = RtfService.deltaToRtf(delta([
        {'insert': {'image': dataUri('image/jpeg', jpeg)}},
        {'insert': '\n'},
      ]));
      expect(images(rtf).single['insert']['image'],
          dataUri('image/jpeg', jpeg));
    });

    test('an unsized image keeps its natural size up to the editor default', () {
      final rtf = RtfService.deltaToRtf(delta([
        {'insert': {'image': dataUri('image/png', png)}},
        {'insert': '\n'},
      ]));
      // 30px is below the editor's 80px minimum display width, so it reads
      // back unsized and shows at its natural size again.
      expect(rtf, contains(r'\picwgoal450'));
      expect(images(rtf).single.containsKey('attributes'), isFalse);
    });
  });

  group('import', () {
    String hex(Uint8List b) {
      const digits = '0123456789abcdef';
      final out = Uint8List(b.length * 2);
      for (var i = 0; i < b.length; i++) {
        out[2 * i] = digits.codeUnitAt(b[i] >> 4);
        out[2 * i + 1] = digits.codeUnitAt(b[i] & 15);
      }
      return latin1.decode(out);
    }

    test("Word's shppict/nonshppict pair gives one image and no stray text",
        () {
      final rtf = '{\\rtf1\\ansi Hello '
          '{\\*\\shppict{\\pict{\\*\\picprop}\\pngblip\\picscalex50\\picscaley50'
          '\\picwgoal6000\\pichgoal4000 ${hex(png)}}}'
          '{\\nonshppict{\\pict\\wmetafile8\\picw30\\pich20 0102030405}}'
          ' world\\par}';
      final found = images(rtf);
      expect(found, hasLength(1));
      expect(found.single['insert']['image'], dataUri('image/png', png));
      expect(found.single['attributes'], {'style': 'width: 200px;'});
      expect(plainText(rtf), 'Hello  world\n');
    });

    test('a WMF picture is skipped without leaking its data as text', () {
      final rtf = '{\\rtf1\\ansi A{\\pict\\wmetafile8\\picw10\\pich10 '
          '0100090000036e00}B\\par}';
      expect(images(rtf), isEmpty);
      expect(plainText(rtf), 'AB\n');
    });

    test(r'a \bin payload is skipped', () {
      final rtf = '{\\rtf1\\ansi A{\\pict\\pngblip\\bin4 xxxx}B\\par}';
      expect(images(rtf), isEmpty);
      expect(plainText(rtf), 'AB\n');
    });

    test('data that does not match its declared type is skipped', () {
      final rtf =
          '{\\rtf1\\ansi {\\pict\\pngblip ${hex(jpeg)}}\\par}';
      expect(images(rtf), isEmpty);
    });

    test('an image over the 4 MB ceiling is skipped', () {
      final big = Uint8List(4 * 1024 * 1024 + 16)
        ..setRange(0, 8, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
      final rtf = '{\\rtf1\\ansi {\\pict\\pngblip ${hex(big)}}x\\par}';
      expect(images(rtf), isEmpty);
      expect(plainText(rtf), 'x\n');
    });

    test('a document that ends on an image still parses', () {
      final rtf = '{\\rtf1\\ansi {\\pict\\pngblip ${hex(png)}}}';
      final result = ops(rtf);
      expect(result.first['insert'], isA<Map>());
      expect(result.last['insert'], '\n');
    });
  });

  group('review hardening', () {
    String hex(Uint8List b) {
      const digits = '0123456789abcdef';
      final out = Uint8List(b.length * 2);
      for (var i = 0; i < b.length; i++) {
        out[2 * i] = digits.codeUnitAt(b[i] >> 4);
        out[2 * i + 1] = digits.codeUnitAt(b[i] & 15);
      }
      return latin1.decode(out);
    }

    /// A PNG header declaring [w] x [h], padded to [size] bytes. Export reads
    /// only the header for PNGs, so this stands in for a large real image.
    Uint8List pngHeader(int w, int h, {int size = 64}) {
      final b = Uint8List(size);
      b.setRange(0, 8, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
      b.setRange(8, 16, [0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52]); // IHDR
      ByteData.sublistView(b)
        ..setUint32(16, w)
        ..setUint32(20, h);
      return b;
    }

    String oneImage(Map<String, dynamic> insert, [Map? attrs]) => delta([
          {'insert': insert, 'attributes': ?attrs},
          {'insert': '\n'},
        ]);

    test('the image type comes from its bytes, not the declared MIME', () {
      final d = oneImage({'image': dataUri('image/png', jpeg)});
      final out = RtfService.exportDelta(d);
      expect(out.dropped, isFalse);
      expect(out.rtf, contains(r'\jpegblip'));
      final upper = oneImage({'image': dataUri('IMAGE/PNG', png)});
      expect(RtfService.exportDelta(upper).dropped, isFalse);
    });

    test('a PNG with no IEND chunk is still kept', () {
      final truncated = Uint8List.sublistView(png, 0, png.length - 12);
      final out =
          RtfService.exportDelta(oneImage({'image': dataUri('image/png', truncated)}));
      expect(out.dropped, isFalse);
      expect(out.rtf, contains(r'\pngblip\picw30\pich20'));
    });

    test('WebP and BMP are converted to PNG', () {
      const webp = 'data:image/webp;base64,'
          'UklGRhoAAABXRUJQVlA4TA0AAAAvAAAAEAcQERGIiP4HAA==';
      final bmp = img.encodeBmp(picture(5, 4));
      for (final d in [
        oneImage({'image': webp}),
        oneImage({'image': dataUri('image/bmp', bmp)}),
      ]) {
        final out = RtfService.exportDelta(d);
        expect(out.dropped, isFalse);
        expect(out.rtf, contains(r'\pngblip'));
      }
    });

    test('what is reported as kept is what is written', () {
      final inputs = <String>[
        oneImage({'image': dataUri('image/png', png)}),
        oneImage({'image': dataUri('image/jpeg', jpeg)}),
        oneImage({'image': dataUri('image/gif', gif)}),
        oneImage({'image': svg}),
        oneImage({'image': 'data:image/png;base64,AAAA'}),
        oneImage({'image': 'https://example.com/x.png'}),
        oneImage({'custom': '{"scrib-table":"{}"}'}),
        oneImage({'video': 'x'}),
        oneImage({'image': dataUri('image/png', pngHeader(20000, 20000))}),
        delta([
          {'insert': 'a'},
          {'insert': {'image': dataUri('image/png', png)}},
          {'insert': {'image': svg}},
          {'insert': {'image': dataUri('image/jpeg', jpeg)}},
          {'insert': '\n'},
        ]),
      ];
      for (final d in inputs) {
        final embeds = (jsonDecode(d) as List)
            .where((op) => op['insert'] is! String)
            .length;
        final out = RtfService.exportDelta(d);
        final picts = RegExp(r'\\pict\\').allMatches(out.rtf).length;
        expect(out.dropped, picts != embeds,
            reason: d.length > 60 ? d.substring(0, 60) : d);
      }
    });

    test('an image wider or taller than the ceiling is not written or read', () {
      final huge = dataUri('image/png', pngHeader(20000, 20000));
      expect(RtfService.exportDelta(oneImage({'image': huge})).dropped, isTrue);
      final rtf = '{\\rtf1\\ansi {\\pict\\pngblip ${hex(pngHeader(20000, 20000))}}x\\par}';
      expect(images(rtf), isEmpty);
    });

    test('pictures that would make an .rtf too big to reopen are left out',
        () {
      // Nine 3.9 MB pictures make about 71 MB of hex, over the 64 MB read cap.
      final big = dataUri('image/png', pngHeader(100, 100, size: 3900000));
      final d = delta([
        for (var i = 0; i < 9; i++) ...[
          {'insert': {'image': big}},
          {'insert': '\n'},
        ],
      ]);
      final out = RtfService.exportDelta(d);
      expect(out.dropped, isTrue);
      expect(out.rtf.length, lessThanOrEqualTo(FileService.maxReadBytes));
      expect(RegExp(r'\\pict\\').allMatches(out.rtf).length, inInclusiveRange(1, 8));
    });

    test('at most 500 pictures are read from one file', () {
      final one = '{\\pict\\pngblip ${hex(png)}}';
      final rtf = '{\\rtf1\\ansi ${List.filled(501, one).join()}\\par}';
      expect(images(rtf), hasLength(500));
    });

    test('a link on an image survives the round trip', () {
      final rtf = RtfService.deltaToRtf(oneImage(
          {'image': dataUri('image/png', png)}, {'link': 'https://scrib.blog'}));
      expect(rtf, contains('HYPERLINK "https://scrib.blog"'));
      expect(images(rtf).single['attributes'], {'link': 'https://scrib.blog'});
    });

    test('an image in a header paragraph keeps the header', () {
      final rtf = RtfService.deltaToRtf(delta([
        {'insert': 'Title '},
        {'insert': {'image': dataUri('image/png', png)}},
        {'insert': '\n', 'attributes': {'header': 1}},
      ]));
      final result = ops(rtf);
      expect(result.whereType<Map>().where((o) => o['insert'] is Map), hasLength(1));
      expect(result.last['attributes'], {'header': 1});
    });

    test('broken picture groups never throw or leak text', () {
      final cases = [
        '{\\rtf1\\ansi A{\\pict\\pngblip ${hex(png)}', // unterminated
        '{\\rtf1\\ansi A{\\pict\\pngblip ${hex(png)}f}B\\par}', // odd digits
        '{\\rtf1\\ansi A{\\*\\shppict some text {\\other x}}B\\par}', // no pict
        "{\\rtf1\\ansi A{\\pict\\pngblip \\'41\\'42}B\\par}", // escapes
      ];
      for (final rtf in cases) {
        expect(() => RtfService.rtfToDelta(rtf), returnsNormally);
        expect(plainText(rtf), isNot(contains('text')));
        expect(plainText(rtf), isNot(contains('89504e47')));
      }
      expect(plainText(cases[2]), 'AB\n');
    });
  });

  group('save paths', () {
    late Directory tmp;
    late SettingsService settings;
    late EditorProvider editor;
    late FileService fs;
    late FileOperations ops;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('scrib_rtf_images_');
      settings = SettingsService();
      await settings.initForTests(tmp.path);
      fs = FileService();
      editor = EditorProvider(fs, settings);
      ops = FileOperations(fs, settings);
    });

    tearDown(() async {
      editor.dispose();
      await Hive.close();
      try { await tmp.delete(recursive: true); } catch (_) {}
    });

    String path(String name) => '${tmp.path}${Platform.pathSeparator}$name';

    Future<void> openRichRtf(String name, String deltaJson) async {
      await fs.writeRtfFile(path(name), RtfService.deltaToRtf(
          '[{"insert":"start\\n"}]'));
      await editor.openRtfFile(path(name),
          RtfService.rtfToDelta(await fs.readRtfFile(path(name))));
      editor.updateDeltaJson(deltaJson);
    }

    final withPng = jsonEncode([
      {'insert': 'Photo:\n'},
      {'insert': {'image': 'data:image/png;base64,${base64Encode(png)}'}},
      {'insert': '\n'},
    ]);

    test('Ctrl+S on a .rtf with a PNG saves it without asking', () async {
      await openRichRtf('photo.rtf', withPng);
      var asked = false;

      final r = await ops.saveActive(editor,
          passwordForNewEncryption: null,
          confirmLossyRtf: () async {
            asked = true;
            return false;
          });

      expect(r.ok, isTrue);
      expect(asked, isFalse);
      expect(editor.activeTab!.isDirty, isFalse);
      final reopened = RtfService.rtfToDelta(await fs.readRtfFile(path('photo.rtf')));
      expect(reopened, contains(base64Encode(png)));
    });

    test('auto-save writes a .rtf with a PNG instead of deferring it',
        () async {
      await openRichRtf('auto.rtf', withPng);

      expect(await editor.saveAllSaveable(), isTrue);

      expect(await fs.readRtfFile(path('auto.rtf')), contains(r'\pngblip'));
    });

    test('an SVG still makes auto-save defer and Ctrl+S ask', () async {
      await openRichRtf('vector.rtf', jsonEncode([
        {'insert': {'image': svg}},
        {'insert': '\n'},
      ]));

      expect(await editor.saveAllSaveable(), isFalse);
      var asked = false;
      final r = await ops.saveActive(editor,
          passwordForNewEncryption: null,
          confirmLossyRtf: () async {
            asked = true;
            return false;
          });
      expect(asked, isTrue);
      expect(r.ok, isFalse);
      expect(editor.activeTab!.isDirty, isTrue);
    });
  });
}
