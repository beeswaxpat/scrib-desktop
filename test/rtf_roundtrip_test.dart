import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrib_desktop/services/rtf_service.dart';

/// Focused tests for the RTF correctness fixes: signed \uN, surrogate pairs,
/// \uN import decoding, cp1252 hex bytes, \ul0, the \'XX end-of-string
/// off-by-one, and graceful handling of malformed Delta. Plus round-trips.
void main() {
  String textOf(String delta) =>
      (jsonDecode(delta) as List).map((o) => (o as Map)['insert']).join();

  Map<String, dynamic>? attrsOfInsert(String delta, String insert) {
    final ops = jsonDecode(delta) as List;
    for (final o in ops) {
      if ((o as Map)['insert'] == insert) {
        return (o['attributes'] as Map?)?.cast<String, dynamic>();
      }
    }
    return null;
  }

  group('unicode escape (export)', () {
    test('a high-BMP CJK char emits a SIGNED \\uN escape', () {
      final delta = jsonEncode([
        {'insert': '鿿\n'} // U+9FFF, code unit 40959 -> signed -24577
      ]);
      final rtf = RtfService.deltaToRtf(delta);
      expect(rtf, contains(r'\u-24577'));
      expect(rtf, isNot(contains(r'䂕9')));
    });

    test('an emoji is emitted as two signed surrogate escapes', () {
      final delta = jsonEncode([
        {'insert': '\u{1F600}\n'} // 😀 -> D83D DE00 -> -10179, -8704
      ]);
      final rtf = RtfService.deltaToRtf(delta);
      expect(rtf, contains(r'\u-10179'));
      expect(rtf, contains(r'\u-8704'));
    });

    test('a low accented char stays positive', () {
      final delta = jsonEncode([
        {'insert': 'café\n'} // é = 233
      ]);
      final rtf = RtfService.deltaToRtf(delta);
      expect(rtf, contains(r'\u233'));
    });
  });

  group('unicode round-trips (export then import)', () {
    test('an emoji survives delta -> rtf -> delta', () {
      final delta = jsonEncode([
        {'insert': 'hi \u{1F600} there\n'}
      ]);
      final back = RtfService.rtfToDelta(RtfService.deltaToRtf(delta));
      expect(textOf(back), contains('\u{1F600}'));
    });

    test('accented Latin text survives the round-trip', () {
      final delta = jsonEncode([
        {'insert': 'café résumé naïve\n'}
      ]);
      final back = RtfService.rtfToDelta(RtfService.deltaToRtf(delta));
      expect(textOf(back), contains('café'));
      expect(textOf(back), contains('naïve'));
    });

    test('a CJK string survives the round-trip', () {
      final delta = jsonEncode([
        {'insert': '你好世界\n'} // 你好世界
      ]);
      final back = RtfService.rtfToDelta(RtfService.deltaToRtf(delta));
      expect(textOf(back), contains('你好世界'));
    });
  });

  group('import control words', () {
    test('a bare \\u escape decodes and skips its fallback char', () {
      final delta = RtfService.rtfToDelta(r'{\rtf1\ansi\deff0 A\u233?B\par}');
      expect(textOf(delta), contains('AéB'));
    });

    test('a negative \\u escape decodes to the right BMP char', () {
      // -24577 + 65536 = 40959 = U+9FFF
      final delta = RtfService.rtfToDelta(r'{\rtf1\ansi\deff0 \u-24577?\par}');
      expect(textOf(delta), contains('鿿'));
    });

    test('\\ul0 does NOT underline the following text', () {
      final delta = RtfService.rtfToDelta(r'{\rtf1\ansi\deff0 \ul0 plain\par}');
      expect(attrsOfInsert(delta, 'plain')?['underline'], isNot(true));
    });

    test('\\ul enables underline (no param)', () {
      final delta = RtfService.rtfToDelta(r'{\rtf1\ansi\deff0 \ul under\par}');
      final ops = jsonDecode(delta) as List;
      final hasUnderline = ops.any((o) => (o as Map)['attributes']?['underline'] == true);
      expect(hasUnderline, isTrue);
    });

    test('\\tab maps to a tab character', () {
      final delta = RtfService.rtfToDelta(r'{\rtf1\ansi\deff0 a\tab b\par}');
      expect(textOf(delta), contains('\t'));
    });

    test('\\plain resets all active formatting', () {
      final delta = RtfService.rtfToDelta(
          r'{\rtf1\ansi\deff0 \b bold\plain  normal\par}');
      expect(attrsOfInsert(delta, ' normal'), anyOf(isNull, isNot(contains('bold'))));
    });
  });

  group('cp1252 hex escapes', () {
    // Real RTF always carries a font table; bodies are delimited after it. (The
    // first-token-after-bare-header case is a separate known parser limitation.)
    const head = r'{\rtf1\ansi\deff0{\fonttbl{\f0\fswiss Arial;}}';

    test("\\'92 decodes to a right single quote U+2019", () {
      final delta = RtfService.rtfToDelta('${head}it\\\'92s\\par}');
      expect(textOf(delta), contains('’'));
    });

    test("\\'95 decodes to a bullet U+2022", () {
      final delta = RtfService.rtfToDelta('$head\\\'95 item\\par}');
      expect(textOf(delta), contains('•'));
    });

    test("a plain ASCII \\'41 decodes to 'A'", () {
      final delta = RtfService.rtfToDelta('${head}X\\\'41BC\\par}');
      expect(textOf(delta), contains('XABC'));
    });

    test("a trailing \\'41 flush against end-of-content still decodes", () {
      final delta = RtfService.rtfToDelta('${head}Z\\\'41}');
      expect(textOf(delta), contains('ZA'));
    });
  });

  group('attribute round-trips', () {
    test('bold + italic survive', () {
      final delta = jsonEncode([
        {'insert': 'styled', 'attributes': {'bold': true, 'italic': true}},
        {'insert': '\n'}
      ]);
      final back = RtfService.rtfToDelta(RtfService.deltaToRtf(delta));
      final attrs = attrsOfInsert(back, 'styled');
      expect(attrs?['bold'], true);
      expect(attrs?['italic'], true);
    });

    test('strikethrough survives', () {
      final delta = jsonEncode([
        {'insert': 'struck', 'attributes': {'strike': true}},
        {'insert': '\n'}
      ]);
      final back = RtfService.rtfToDelta(RtfService.deltaToRtf(delta));
      expect(attrsOfInsert(back, 'struck')?['strike'], true);
    });

    test('font size 24 survives as 24 (\\fs48)', () {
      final delta = jsonEncode([
        {'insert': 'big', 'attributes': {'size': 24}},
        {'insert': '\n'}
      ]);
      final rtf = RtfService.deltaToRtf(delta);
      expect(rtf, contains(r'\fs48'));
      final back = RtfService.rtfToDelta(rtf);
      expect(attrsOfInsert(back, 'big')?['size'], 24);
    });

    test('three plain paragraphs survive the round-trip', () {
      final delta = jsonEncode([
        {'insert': 'one\ntwo\nthree\n'}
      ]);
      final back = RtfService.rtfToDelta(RtfService.deltaToRtf(delta));
      final t = textOf(back);
      expect(t, contains('one'));
      expect(t, contains('two'));
      expect(t, contains('three'));
    });
  });

  group('block formatting (export)', () {
    test('H1 emits a bold size-48 group', () {
      final delta = jsonEncode([
        {'insert': 'Title'},
        {'insert': '\n', 'attributes': {'header': 1}},
      ]);
      final rtf = RtfService.deltaToRtf(delta);
      expect(rtf, contains(r'\fs48'));
    });

    test('header levels map to the documented sizes', () {
      const sizes = {1: 48, 2: 40, 3: 32, 4: 28, 5: 24, 6: 20};
      sizes.forEach((level, fs) {
        final delta = jsonEncode([
          {'insert': 'H'},
          {'insert': '\n', 'attributes': {'header': level}},
        ]);
        expect(RtfService.deltaToRtf(delta), contains('\\fs$fs'));
      });
    });

    test('an out-of-range header level produces no header group', () {
      final delta = jsonEncode([
        {'insert': 'x'},
        {'insert': '\n', 'attributes': {'header': 9}},
      ]);
      final rtf = RtfService.deltaToRtf(delta);
      // Header groups open with `{\b\fs<size>`; the font table's \fswiss must
      // not be mistaken for one, so match the header-specific prefix.
      expect(rtf, isNot(contains(r'\b\fs')));
    });

    test('blockquote emits a left indent', () {
      final delta = jsonEncode([
        {'insert': 'quote'},
        {'insert': '\n', 'attributes': {'blockquote': true}},
      ]);
      expect(RtfService.deltaToRtf(delta), contains(r'\li720'));
    });
  });

  group('malformed input is handled gracefully', () {
    test('deltaToRtf on non-JSON returns a valid RTF wrapper and does not throw', () {
      final rtf = RtfService.deltaToRtf('this is not json {[}');
      expect(rtf, startsWith(r'{\rtf1'));
      expect(rtf, endsWith('}'));
    });

    test('deltaToRtf on a JSON object (not a list) does not throw', () {
      final rtf = RtfService.deltaToRtf('{"unexpected":"object"}');
      expect(rtf, startsWith(r'{\rtf1'));
    });

    test('deltaToRtf with a numeric font attribute does not throw', () {
      final delta = jsonEncode([
        {'insert': 'x', 'attributes': {'font': 12}},
        {'insert': '\n'}
      ]);
      expect(() => RtfService.deltaToRtf(delta), returnsNormally);
    });

    test('deltaToRtf with a non-string embed insert is skipped', () {
      final delta = jsonEncode([
        {'insert': {'image': 'x.png'}},
        {'insert': 'after\n'}
      ]);
      final rtf = RtfService.deltaToRtf(delta);
      expect(rtf, contains('after'));
    });

    test('escaped braces and backslash survive export', () {
      final delta = jsonEncode([
        {'insert': r'a\b{c}d' '\n'}
      ]);
      final rtf = RtfService.deltaToRtf(delta);
      expect(rtf, contains(r'a\\b\{c\}d'));
    });

    test('empty delta produces a valid RTF header', () {
      final rtf = RtfService.deltaToRtf('');
      expect(rtf, startsWith(r'{\rtf1'));
      expect(rtf, endsWith('}'));
    });

    test('non-RTF input to rtfToDelta is treated as plain text', () {
      final delta = RtfService.rtfToDelta('just plain text');
      expect(textOf(delta), contains('just plain text'));
    });
  });
}
