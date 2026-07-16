import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrib_desktop/services/rtf_service.dart';

/// Round-trip fidelity and robustness tests for the RTF fixes:
/// 1. group-scoped inline state (no formatting bleed past '}')
/// 2. {\*\...} ignorable destinations are skipped (no WordPad/Word garbage)
/// 3. multi-font tables parse fully (not just \f0)
/// 4. block structure (ordered numbering, lists, headers, quotes) round-trips
/// 5. hyperlinks ({\field{\*\fldinst HYPERLINK ...}}) and sub/superscript
/// 6. hostile/malformed RTF never crashes or hangs (bounded depth)
void main() {
  String textOf(String delta) =>
      (jsonDecode(delta) as List).map((o) => (o as Map)['insert']).join();

  List<Map<String, dynamic>> opsOf(String delta) => (jsonDecode(delta) as List)
      .map((o) => (o as Map).cast<String, dynamic>())
      .toList();

  Map<String, dynamic>? attrsOfInsert(String delta, String insert) {
    for (final o in opsOf(delta)) {
      if (o['insert'] == insert) {
        return (o['attributes'] as Map?)?.cast<String, dynamic>();
      }
    }
    return null;
  }

  /// Attributes of the paragraph-terminating '\n' op that FOLLOWS the op
  /// whose insert equals [insert].
  Map<String, dynamic>? blockAttrsAfter(String delta, String insert) {
    final ops = opsOf(delta);
    for (int i = 0; i < ops.length; i++) {
      if (ops[i]['insert'] == insert) {
        for (int j = i + 1; j < ops.length; j++) {
          final ins = ops[j]['insert'];
          if (ins is String && ins.contains('\n')) {
            return (ops[j]['attributes'] as Map?)?.cast<String, dynamic>();
          }
        }
      }
    }
    return null;
  }

  int braceBalance(String rtf) {
    int depth = 0;
    for (int i = 0; i < rtf.length; i++) {
      final c = rtf[i];
      final escaped = i > 0 && rtf[i - 1] == r'\';
      if (escaped) continue;
      if (c == '{') depth++;
      if (c == '}') depth--;
    }
    return depth;
  }

  String roundTrip(List<Map<String, dynamic>> ops) =>
      RtfService.rtfToDelta(RtfService.deltaToRtf(jsonEncode(ops)));

  group('group-scoped inline state (finding 1)', () {
    test('Scrib export of a mixed-bold paragraph round-trips without bleed', () {
      final back = roundTrip([
        {'insert': 'bold', 'attributes': {'bold': true}},
        {'insert': ' normal\n'},
      ]);
      expect(attrsOfInsert(back, 'bold')?['bold'], true);
      expect(attrsOfInsert(back, ' normal')?['bold'], isNot(true));
    });

    test('{\\b bold} normal: bold ends at the group close', () {
      final delta = RtfService.rtfToDelta(
        r'{\rtf1\ansi\deff0{\fonttbl{\f0\fswiss Arial;}}{\b bold} normal\par}',
      );
      expect(attrsOfInsert(delta, 'bold')?['bold'], true);
      expect(attrsOfInsert(delta, ' normal')?['bold'], isNot(true));
    });

    test('font run ends at the group close', () {
      final delta = RtfService.rtfToDelta(
        r'{\rtf1\ansi\deff0{\fonttbl{\f0\fswiss Arial;}{\f1\fmodern Consolas;}}'
        r'{\f1 code} normal\par}',
      );
      expect(attrsOfInsert(delta, 'code')?['font'], 'Consolas');
      expect(attrsOfInsert(delta, ' normal')?['font'], isNull);
    });

    test('size run ends at the group close', () {
      final delta = RtfService.rtfToDelta(
        r'{\rtf1\ansi\deff0{\fonttbl{\f0\fswiss Arial;}}{\fs48 big} small\par}',
      );
      expect(attrsOfInsert(delta, 'big')?['size'], 24);
      expect(attrsOfInsert(delta, ' small')?['size'], isNull);
    });

    test('nested groups restore each level', () {
      final delta = RtfService.rtfToDelta(
        r'{\rtf1\ansi\deff0{\fonttbl{\f0\fswiss Arial;}}'
        r'{\b bold {\i both} bold2} plain\par}',
      );
      expect(attrsOfInsert(delta, 'both')?['bold'], true);
      expect(attrsOfInsert(delta, 'both')?['italic'], true);
      expect(attrsOfInsert(delta, ' bold2')?['bold'], true);
      expect(attrsOfInsert(delta, ' bold2')?['italic'], isNot(true));
      expect(attrsOfInsert(delta, ' plain'), isNull);
    });

    test('explicit \\b0 switch still overrides inside a group', () {
      final delta = RtfService.rtfToDelta(
        r'{\rtf1\ansi\deff0{\fonttbl{\f0\fswiss Arial;}}\b bold\b0  plain\par}',
      );
      expect(attrsOfInsert(delta, 'bold')?['bold'], true);
      expect(attrsOfInsert(delta, ' plain')?['bold'], isNot(true));
    });
  });

  group('ignorable destinations are skipped (finding 2)', () {
    test('WordPad generator group does not leak into the note', () {
      final delta = RtfService.rtfToDelta(
        '{\\rtf1\\ansi\\ansicpg1252\\deff0\\nouicompat'
        '{\\fonttbl{\\f0\\fnil\\fcharset0 Calibri;}}\n'
        '{\\*\\generator Riched20 10.0.19041}\\viewkind4\\uc1 \n'
        '\\pard\\sa200\\sl276\\slmult1\\f0\\fs22\\lang9 Hello from WordPad\\par\n'
        '}',
      );
      final text = textOf(delta);
      expect(text, contains('Hello from WordPad'));
      expect(text, isNot(contains('Riched20')));
      expect(text, isNot(contains('*')));
    });

    test('Word theme/datastore payloads are skipped', () {
      final delta = RtfService.rtfToDelta(
        r'{\rtf1\ansi\deff0{\fonttbl{\f0\fswiss Arial;}}'
        r'{\*\themedata 504b030414000600080000002100}body text\par}',
      );
      final text = textOf(delta);
      expect(text, contains('body text'));
      expect(text, isNot(contains('504b')));
    });

    test('formatting state survives an interleaved destination group', () {
      final delta = RtfService.rtfToDelta(
        r'{\rtf1\ansi\deff0{\fonttbl{\f0\fswiss Arial;}}'
        r'\b one {\*\bkmkstart mark}two\par}',
      );
      // The destination contributes nothing and the surrounding run stays
      // bold and contiguous.
      expect(attrsOfInsert(delta, 'one two')?['bold'], true);
      expect(textOf(delta), isNot(contains('mark')));
    });
  });

  group('multi-font table (finding 3)', () {
    test('every entry in a three-font table resolves', () {
      final delta = RtfService.rtfToDelta(
        r'{\rtf1\ansi\deff0{\fonttbl{\f0\fswiss Arial;}{\f1\fmodern Consolas;}'
        r'{\f2\froman Georgia;}}'
        r'{\f1 one}{\f2 two}\par}',
      );
      expect(attrsOfInsert(delta, 'one')?['font'], 'Consolas');
      expect(attrsOfInsert(delta, 'two')?['font'], 'Georgia');
    });

    test('multi-word font names survive (not just the last word)', () {
      final delta = RtfService.rtfToDelta(
        r'{\rtf1\ansi\deff0{\fonttbl{\f0\fswiss Arial;}'
        r'{\f1\froman\fcharset0 Times New Roman;}}'
        r'{\f1 serif text}\par}',
      );
      expect(attrsOfInsert(delta, 'serif text')?['font'], 'Times New Roman');
    });

    test('Scrib multi-font export round-trips the font choices', () {
      final back = roundTrip([
        {'insert': 'mono', 'attributes': {'font': 'Consolas'}},
        {'insert': ' and '},
        {'insert': 'serif', 'attributes': {'font': 'Georgia'}},
        {'insert': '\n'},
      ]);
      expect(attrsOfInsert(back, 'mono')?['font'], 'Consolas');
      expect(attrsOfInsert(back, 'serif')?['font'], 'Georgia');
      expect(attrsOfInsert(back, ' and ')?['font'], isNull);
    });
  });

  group('block structure round-trip (finding 4)', () {
    test('ordered list exports visible numbers that restart after a break', () {
      final rtf = RtfService.deltaToRtf(jsonEncode([
        {'insert': 'first'},
        {'insert': '\n', 'attributes': {'list': 'ordered'}},
        {'insert': 'second'},
        {'insert': '\n', 'attributes': {'list': 'ordered'}},
        {'insert': 'break\n'},
        {'insert': 'restart'},
        {'insert': '\n', 'attributes': {'list': 'ordered'}},
      ]));
      expect(braceBalance(rtf), 0);
      expect(rtf, contains(r'1.\tab first'));
      expect(rtf, contains(r'2.\tab second'));
      expect(rtf, contains(r'1.\tab restart'));
    });

    test('ordered list round-trips: attribute restored, marker stripped', () {
      final back = roundTrip([
        {'insert': 'first'},
        {'insert': '\n', 'attributes': {'list': 'ordered'}},
        {'insert': 'second'},
        {'insert': '\n', 'attributes': {'list': 'ordered'}},
      ]);
      expect(blockAttrsAfter(back, 'first')?['list'], 'ordered');
      expect(blockAttrsAfter(back, 'second')?['list'], 'ordered');
      expect(textOf(back), isNot(contains('1.')));
      expect(textOf(back), isNot(contains('2.')));
    });

    test('bullet list round-trips: attribute restored, glyph stripped', () {
      final back = roundTrip([
        {'insert': 'item one'},
        {'insert': '\n', 'attributes': {'list': 'bullet'}},
      ]);
      expect(blockAttrsAfter(back, 'item one')?['list'], 'bullet');
      expect(textOf(back), isNot(contains('•')));
    });

    test('checklist round-trips both states, markers stripped', () {
      final back = roundTrip([
        {'insert': 'buy milk'},
        {'insert': '\n', 'attributes': {'list': 'unchecked'}},
        {'insert': 'done thing'},
        {'insert': '\n', 'attributes': {'list': 'checked'}},
      ]);
      expect(blockAttrsAfter(back, 'buy milk')?['list'], 'unchecked');
      expect(blockAttrsAfter(back, 'done thing')?['list'], 'checked');
      expect(textOf(back), isNot(contains('[x]')));
      expect(textOf(back), isNot(contains('[ ]')));
    });

    test('all six header levels round-trip without inline residue', () {
      for (int level = 1; level <= 6; level++) {
        final back = roundTrip([
          {'insert': 'Title$level'},
          {'insert': '\n', 'attributes': {'header': level}},
        ]);
        expect(blockAttrsAfter(back, 'Title$level')?['header'], level,
            reason: 'header $level should survive the round-trip');
        final inline = attrsOfInsert(back, 'Title$level');
        expect(inline?['bold'], isNot(true),
            reason: 'exporter bold must be stripped on header import');
        expect(inline?['size'], isNull,
            reason: 'exporter size must be stripped on header import');
      }
    });

    test('header keeps other inline formatting (italic) on its text', () {
      final back = roundTrip([
        {'insert': 'em', 'attributes': {'italic': true}},
        {'insert': '\n', 'attributes': {'header': 2}},
      ]);
      expect(blockAttrsAfter(back, 'em')?['header'], 2);
      expect(attrsOfInsert(back, 'em')?['italic'], true);
    });

    test('blockquote round-trips', () {
      final back = roundTrip([
        {'insert': 'quoted'},
        {'insert': '\n', 'attributes': {'blockquote': true}},
      ]);
      expect(blockAttrsAfter(back, 'quoted')?['blockquote'], true);
    });

    test('plain paragraph after a blockquote stays plain', () {
      final back = roundTrip([
        {'insert': 'quoted'},
        {'insert': '\n', 'attributes': {'blockquote': true}},
        {'insert': 'plain\n'},
      ]);
      expect(blockAttrsAfter(back, 'plain'), isNull);
    });

    test('Word-style numbered list item imports as ordered', () {
      final delta = RtfService.rtfToDelta(
        r'{\rtf1\ansi\deff0{\fonttbl{\f0\fswiss Arial;}}'
        '\\pard{\\listtext\\f0 1.\\tab}\\fi-360\\li720 word item\\par}',
      );
      expect(blockAttrsAfter(delta, 'word item')?['list'], 'ordered');
    });

    test('kitchen-sink document exports balanced braces', () {
      final rtf = RtfService.deltaToRtf(jsonEncode([
        {'insert': 'Heading'},
        {'insert': '\n', 'attributes': {'header': 1}},
        {'insert': 'a bullet'},
        {'insert': '\n', 'attributes': {'list': 'bullet'}},
        {'insert': 'a number'},
        {'insert': '\n', 'attributes': {'list': 'ordered'}},
        {'insert': 'todo'},
        {'insert': '\n', 'attributes': {'list': 'unchecked'}},
        {'insert': 'quote'},
        {'insert': '\n', 'attributes': {'blockquote': true}},
        {'insert': 'site', 'attributes': {'link': 'https://example.com'}},
        {'insert': ' and '},
        {'insert': 'x', 'attributes': {'script': 'super'}},
        {'insert': '\n'},
      ]));
      expect(braceBalance(rtf), 0);
    });
  });

  group('hyperlinks and sub/superscript (finding 5)', () {
    test('link exports as a HYPERLINK field with the URL present', () {
      final rtf = RtfService.deltaToRtf(jsonEncode([
        {'insert': 'site', 'attributes': {'link': 'https://example.com'}},
        {'insert': '\n'},
      ]));
      expect(braceBalance(rtf), 0);
      expect(rtf, contains(r'{\field{\*\fldinst{HYPERLINK "https://example.com"}}'));
      expect(rtf, contains('site'));
    });

    test('link URL and display text round-trip', () {
      final back = roundTrip([
        {'insert': 'site', 'attributes': {'link': 'https://example.com'}},
        {'insert': ' after\n'},
      ]);
      expect(attrsOfInsert(back, 'site')?['link'], 'https://example.com');
      expect(attrsOfInsert(back, ' after')?['link'], isNull);
    });

    test('bold link keeps both attributes through the round-trip', () {
      final back = roundTrip([
        {
          'insert': 'both',
          'attributes': {'link': 'https://example.com', 'bold': true}
        },
        {'insert': '\n'},
      ]);
      final attrs = attrsOfInsert(back, 'both');
      expect(attrs?['link'], 'https://example.com');
      expect(attrs?['bold'], true);
    });

    test('mailto link round-trips', () {
      final back = roundTrip([
        {'insert': 'mail me', 'attributes': {'link': 'mailto:a@b.com'}},
        {'insert': '\n'},
      ]);
      expect(attrsOfInsert(back, 'mail me')?['link'], 'mailto:a@b.com');
    });

    test('unsafe scheme in an imported HYPERLINK keeps text, drops the link', () {
      final delta = RtfService.rtfToDelta(
        r'{\rtf1\ansi\deff0{\fonttbl{\f0\fswiss Arial;}}'
        r'{\field{\*\fldinst{HYPERLINK "javascript:alert(1)"}}{\fldrslt evil}}\par}',
      );
      expect(textOf(delta), contains('evil'));
      expect(attrsOfInsert(delta, 'evil')?['link'], isNull);
    });

    test('Word-style field with formatting in the result imports the link', () {
      final delta = RtfService.rtfToDelta(
        r'{\rtf1\ansi\deff0{\fonttbl{\f0\fswiss Arial;}}'
        r'{\field{\*\fldinst {HYPERLINK "http://example.org/" }}'
        r'{\fldrslt {\ul\cf2 click here}}}\par}',
      );
      final attrs = attrsOfInsert(delta, 'click here');
      expect(attrs?['link'], 'http://example.org/');
      expect(attrs?['underline'], true);
    });

    test('sub and superscript round-trip via the script attribute', () {
      final back = roundTrip([
        {'insert': 'H'},
        {'insert': '2', 'attributes': {'script': 'sub'}},
        {'insert': 'O and x'},
        {'insert': 'n', 'attributes': {'script': 'super'}},
        {'insert': '\n'},
      ]);
      expect(attrsOfInsert(back, '2')?['script'], 'sub');
      expect(attrsOfInsert(back, 'n')?['script'], 'super');
      expect(attrsOfInsert(back, 'O and x')?['script'], isNull);
    });

    test('\\nosupersub ends a script run on import', () {
      final delta = RtfService.rtfToDelta(
        r'{\rtf1\ansi\deff0{\fonttbl{\f0\fswiss Arial;}}'
        r'\super up\nosupersub  base\par}',
      );
      expect(attrsOfInsert(delta, 'up')?['script'], 'super');
      expect(attrsOfInsert(delta, ' base')?['script'], isNull);
    });
  });

  group('hostile or malformed RTF stays bounded (finding 6 hardening)', () {
    test('unbalanced open braces do not crash and keep the text', () {
      final delta = RtfService.rtfToDelta(
        r'{\rtf1\ansi\deff0{\fonttbl{\f0\fswiss Arial;}}{{{ deep text\par}',
      );
      expect(textOf(delta), contains('deep text'));
    });

    test('excess close braces do not crash', () {
      final delta = RtfService.rtfToDelta(
        r'{\rtf1\ansi\deff0{\fonttbl{\f0\fswiss Arial;}}}}}}text\par}',
      );
      expect(() => jsonDecode(delta), returnsNormally);
    });

    test('thousands of nested groups complete without deep recursion', () {
      final rtf =
          '{\\rtf1\\ansi\\deff0 ${'{' * 5000}\\b x${'}' * 5000}\\par}';
      expect(() => RtfService.rtfToDelta(rtf), returnsNormally);
    });

    test('deeply nested fields are cut off by the recursion bound', () {
      final open =
          '{\\field{\\*\\fldinst{HYPERLINK "https://x.com"}}{\\fldrslt ' * 20;
      final rtf = '{\\rtf1\\ansi\\deff0 $open core${'}}' * 20}\\par}';
      expect(() => RtfService.rtfToDelta(rtf), returnsNormally);
    });

    test('truncated field group does not crash', () {
      final delta = RtfService.rtfToDelta(
        r'{\rtf1\ansi\deff0 {\field{\*\fldinst{HYPERLINK "https://x',
      );
      expect(() => jsonDecode(delta), returnsNormally);
    });

    test('field with no fldrslt contributes no text and no crash', () {
      final delta = RtfService.rtfToDelta(
        r'{\rtf1\ansi\deff0{\fonttbl{\f0\fswiss Arial;}}'
        r'a{\field{\*\fldinst{HYPERLINK "https://x.com"}}}b\par}',
      );
      expect(textOf(delta), contains('ab'));
    });

    test('a stray \\* control symbol in the body does not leak an asterisk', () {
      final delta = RtfService.rtfToDelta(
        r'{\rtf1\ansi\deff0{\fonttbl{\f0\fswiss Arial;}}before\* after\par}',
      );
      expect(textOf(delta), isNot(contains('*')));
      expect(textOf(delta), contains('before'));
      expect(textOf(delta), contains(' after'));
    });

    test('a large document with heavy control-word density parses', () {
      final body = StringBuffer();
      for (int i = 0; i < 20000; i++) {
        body.write('\\b bold\\b0 plain ');
      }
      final rtf = '{\\rtf1\\ansi\\deff0 $body\\par}';
      expect(() => RtfService.rtfToDelta(rtf), returnsNormally);
    });
  });

  group('backwards compatibility with pre-fix Scrib exports', () {
    test('old-style header export (no outlinelevel) still imports as text', () {
      final delta = RtfService.rtfToDelta(
        r'{\rtf1\ansi\deff0{\fonttbl{\f0\fswiss Times New Roman;}}'
        '{\\b\\fs48 Old Title}\\par\nbody\\par\n}',
      );
      expect(textOf(delta), contains('Old Title'));
      final attrs = attrsOfInsert(delta, 'Old Title');
      expect(attrs?['bold'], true);
      // The critical part: the header styling must NOT bleed into the body.
      expect(attrsOfInsert(delta, 'body'), isNull);
    });

    test('old-style bullet export now imports as a real bullet list', () {
      final delta = RtfService.rtfToDelta(
        r'{\rtf1\ansi\deff0{\fonttbl{\f0\fswiss Times New Roman;}}'
        '{\\li720\\fi-360 \\\'95\\tab old item}\\par\n}',
      );
      expect(blockAttrsAfter(delta, 'old item')?['list'], 'bullet');
    });

    test('old-style ordered export (no number) degrades to plain text', () {
      final delta = RtfService.rtfToDelta(
        r'{\rtf1\ansi\deff0{\fonttbl{\f0\fswiss Times New Roman;}}'
        '{\\li720\\fi-360 old ordered}\\par\n}',
      );
      expect(textOf(delta), contains('old ordered'));
      expect(blockAttrsAfter(delta, 'old ordered'), isNull);
    });
  });
}
