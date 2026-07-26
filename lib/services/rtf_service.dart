import 'dart:convert';

import 'format_utils.dart';

/// Converts between Quill Delta JSON and RTF format.
///
/// Supports: bold, italic, underline, strikethrough, sub/superscript,
/// hyperlinks (as `{\field{\*\fldinst HYPERLINK ...}}` fields), font family,
/// font size, text color and highlight (via a `\colortbl`), headers, bullet
/// lists, numbered lists, checklists, and block quotes. Inline formatting is
/// group-scoped on import (a `}` restores the state that was active at the
/// matching `{`), unknown `{\*\...}` destination groups are skipped per the
/// RTF spec, and Scrib's own block markers (bullet/number/checkbox glyphs plus
/// `\outlinelevelN` for headers) are recognized on import so Scrib -> RTF ->
/// Scrib round-trips block structure.
///
/// RTF parsing is best-effort. The parser handles the subset of RTF produced
/// by Word, WordPad, and LibreOffice for simple documents — complex features
/// (nested tables, images, styles) pass through as stripped text. For a
/// byte-perfect RTF exchange, use a dedicated library in a future revision.
///
/// All methods are static — RtfService carries no state.
class RtfService {
  RtfService._();

  // Bounds that keep hostile/malformed RTF from hanging or exhausting memory:
  // group nesting beyond _maxGroupDepth stops pushing state (tracked by an
  // overflow counter so braces still pair up), and \field groups nested beyond
  // _maxFieldDepth are skipped instead of parsed recursively.
  static const int _maxGroupDepth = 128;
  static const int _maxFieldDepth = 8;

  // A crafted \colortbl must not turn into an unbounded allocation, and a
  // document cannot plausibly need more distinct colors than this on export.
  static const int _maxColorTableEntries = 1024;

  // Compiled once — the parser hits these on every token, so per-loop
  // RegExp construction was a measurable cost on large files.
  static final RegExp _ctrlWordPattern = RegExp(r'\\([a-z]+)(-?\d+)?\s?');
  static final RegExp _groupCtrlPattern = RegExp(r'\\([a-z]+)');
  static final RegExp _unicodeFallbackPattern =
      RegExp(r"\\'[0-9a-fA-F]{2}|\\[a-z]+-?\d*\s?");
  static final RegExp _hyperlinkQuotedPattern = RegExp(r'HYPERLINK\s+"([^"]*)"');
  static final RegExp _hyperlinkBarePattern =
      RegExp(r'HYPERLINK\s+([^\s"{}\\]+)');
  // Widened from \d{1,4}: the exporter numbers list items without a bound, so
  // item 10000 stopped round-tripping and its marker became document text.
  static final RegExp _orderedMarkerPattern = RegExp(r'^(\d{1,9})\.\t');
  // Alternation of plain literals with bounded quantifiers: linear, and used
  // only inside an already-delimited \colortbl group.
  static final RegExp _colorComponentPattern =
      RegExp(r'\\(red|green|blue)(\d{1,3})|;');
  static final RegExp _rgbFunctionPattern =
      RegExp(r'^rgba?\(\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})');

  /// Header level -> exported font size in half-points (levels 1-6).
  static const List<int> _headerHalfPointSizes = [48, 40, 32, 28, 24, 20];

  /// Convert Quill Delta JSON string to RTF string.
  ///
  /// Malformed/garbage Delta never throws: on a parse failure the raw string is
  /// exported as escaped plain text inside a valid RTF wrapper.
  static String deltaToRtf(String deltaJson) {
    if (deltaJson.isEmpty) return _wrapRtf('');

    final List<dynamic> ops;
    try {
      final decoded = jsonDecode(deltaJson);
      if (decoded is! List) return _wrapRtf('${_escapeRtf(deltaJson)}\\par\n');
      ops = decoded;
    } catch (_) {
      return _wrapRtf('${_escapeRtf(deltaJson)}\\par\n');
    }
    final fonts = <String>{'Times New Roman'}; // Default font at index 0
    final colors = <int>[];

    // First pass: collect the fonts and colors the document uses. Both need a
    // header table emitted before any run can reference them by index.
    for (final op in ops) {
      if (op is! Map) continue;
      final attrs = _attributesOf(op);
      final font = attrs['font'];
      if (font is String) {
        fonts.add(font);
      }
      for (final key in const ['color', 'background']) {
        final rgb = _parseColorValue(attrs[key]);
        if (rgb != null &&
            !colors.contains(rgb) &&
            colors.length < _maxColorTableEntries) {
          colors.add(rgb);
        }
      }
    }

    final fontList = fonts.toList();

    // Build font table
    final fontTable = StringBuffer('{\\fonttbl');
    for (int i = 0; i < fontList.length; i++) {
      fontTable.write('{\\f$i\\fswiss ${_escapeRtf(fontList[i])};}');
    }
    fontTable.write('}');

    // Build color table. Index 0 is the conventional "auto" slot (the leading
    // ';'), so a color's \cf/\highlight index is its position in `colors`
    // PLUS ONE. _inlineFormatting must apply the same offset or every
    // colored run would be painted with its neighbor's color.
    final colorTable = StringBuffer();
    if (colors.isNotEmpty) {
      colorTable.write('{\\colortbl;');
      for (final rgb in colors) {
        colorTable.write('\\red${(rgb >> 16) & 0xFF}'
            '\\green${(rgb >> 8) & 0xFF}\\blue${rgb & 0xFF};');
      }
      colorTable.write('}');
    }

    // Second pass: group ops into paragraphs.
    // In Quill Delta, block attributes (header, list, blockquote) are on the
    // '\n' op that *ends* the paragraph — not on the text ops before it.
    // We buffer each paragraph's inline content and flush it with the block
    // formatting prepended when we encounter the terminating '\n'.
    final content = StringBuffer();
    final paraBuffer = StringBuffer();
    bool paraHasContent = false;
    // Consecutive ordered-list paragraphs share a counter so the exported
    // numbers read 1. 2. 3.; any other paragraph type restarts it.
    int orderedNumber = 0;

    void flushParagraph(Map<String, dynamic> blockAttrs) {
      if (blockAttrs['list'] == 'ordered') {
        orderedNumber++;
      } else {
        orderedNumber = 0;
      }
      final open = _blockFormattingOpen(blockAttrs, orderedNumber);
      content.write(open);
      content.write(paraBuffer.toString());
      // The close mirrors the open exactly. A separate close that fired on the
      // mere presence of a key emitted a lone '}' for an out-of-range header
      // level or a blockquote value that was not literally true, which closed
      // the document group early: Word and WordPad stopped reading there and
      // treated the rest of the note as trailing garbage.
      if (open.isNotEmpty) content.write('}');
      content.write('\\par\n');
      paraBuffer.clear();
      paraHasContent = false;
    }

    for (final op in ops) {
      if (op is! Map || !op.containsKey('insert')) continue;

      final insert = op['insert'];
      if (insert is! String) continue;

      final attrs = _attributesOf(op);

      if (insert == '\n') {
        // End of paragraph — emit buffered content with block formatting first
        flushParagraph(attrs);
      } else {
        // Split by embedded newlines (plain newlines inside a text run become
        // separate unstyled paragraphs)
        final lines = insert.split('\n');
        final rawLink = attrs['link'];
        // The allowlist applies on the way OUT as well as on the way in: a
        // note that picked up a file://, UNC or javascript: link by paste or
        // by import must not become a Word document carrying a live field that
        // resolves it. The text and its other formatting still export.
        final link =
            rawLink is String && isSafeLaunchUrl(rawLink) ? rawLink : null;
        // The link itself rides in the field instruction; the visible run
        // keeps its other inline formatting inside \fldrslt.
        final inlineAttrs = rawLink is String
            ? (Map<String, dynamic>.from(attrs)..remove('link'))
            : attrs;
        for (int j = 0; j < lines.length; j++) {
          if (lines[j].isNotEmpty) {
            if (link != null) {
              paraBuffer.write(
                  '{\\field{\\*\\fldinst{HYPERLINK "${_escapeFieldUrl(link)}"}}{\\fldrslt ');
            }
            final open = _inlineFormatting(inlineAttrs, fontList, colors);
            paraBuffer.write(open);
            paraBuffer.write(_escapeRtf(lines[j]));
            if (open.isNotEmpty) paraBuffer.write('}');
            if (link != null) {
              paraBuffer.write('}}');
            }
            paraHasContent = true;
          }
          if (j < lines.length - 1) {
            // Embedded newline = paragraph break with no block attributes
            flushParagraph({});
          }
        }
      }
    }

    // Flush any trailing content that wasn't terminated by a '\n' op
    if (paraHasContent) {
      content.write(paraBuffer.toString());
      content.write('\\par\n');
    }

    return _wrapRtf(content.toString(),
        fontTable: fontTable.toString(), colorTable: colorTable.toString());
  }

  /// Parse RTF string to Quill Delta JSON string.
  ///
  /// Pure static String -> String with no platform dependencies, so callers
  /// that open very large files could offload it via compute(); today it runs
  /// synchronously on the caller's isolate.
  static String rtfToDelta(String rtfContent) {
    if (rtfContent.isEmpty || !rtfContent.startsWith('{\\rtf')) {
      // Not RTF, treat as plain text
      return jsonEncode([
        {'insert': '$rtfContent\n'}
      ]);
    }

    final ops = <Map<String, dynamic>>[];
    final fonts = _parseFontTable(rtfContent);
    final colors = _parseColorTable(rtfContent);

    // The whole {\rtf1 ...} document goes to the parser. A header-stripping
    // pre-pass used to run first and declared the header over at the first
    // depth-1 character that was neither '{' nor '\', which a closing brace
    // satisfies, so a file with no font table lost its entire first body
    // group, and a leading \'93 smart quote was decapitated into literal text.
    // The pre-pass was never load-bearing: _parseRtfContent already skips
    // \fonttbl, \colortbl, \stylesheet, \info and \pict groups by name, and
    // the outer group's braces simply pair up on the inline-state stack.
    _parseRtfContent(rtfContent, ops, fonts, colors, _RtfInlineState(), 0);

    // Ensure document ends with newline
    if (ops.isEmpty || !(ops.last['insert'] as String).endsWith('\n')) {
      ops.add({'insert': '\n'});
    }

    return jsonEncode(ops);
  }

  /// Extract the full font table with a brace-balanced scan, one entry at a
  /// time. A single regex pairing a lazy `[^}]*?` with a greedy run over the
  /// whole table backtracked quadratically whenever the table carried no `;}`
  /// terminator: a crafted 256KB .rtf froze the window for 38 seconds with no
  /// cancel, and because the file lands in the session snapshot, every
  /// subsequent launch froze again before the window was usable.
  static Map<int, String> _parseFontTable(String rtfContent) {
    final fonts = <int, String>{};
    const marker = '{\\fonttbl';
    final start = rtfContent.indexOf(marker);
    if (start < 0) return fonts;
    final end = _skipGroup(rtfContent, start + 1);
    final table = rtfContent.substring(start, end);

    int i = marker.length;
    while (i < table.length) {
      if (table[i] != '{') {
        i++;
        continue;
      }
      final entryEnd = _skipGroup(table, i + 1);
      final inner =
          table.substring(i + 1, entryEnd > i + 1 ? entryEnd - 1 : entryEnd);
      _readFontEntry(inner, fonts);
      i = entryEnd > i ? entryEnd : i + 1;
    }
    return fonts;
  }

  /// Read one font-table entry (the text between its braces, e.g.
  /// `\f1\froman\fcharset0 Times New Roman;`) into [fonts]. The name is
  /// everything after the entry's last PROPERTY control word, so multi-word
  /// names survive; character escapes (`\'XX`, `\uN`) belong to the name, and
  /// a nested `{\*\falt ...}` alternate name is ignored.
  static void _readFontEntry(String inner, Map<int, String> fonts) {
    if (!inner.startsWith('\\f')) return;
    int p = 2;
    final digitsStart = p;
    while (p < inner.length && _isDigit(inner.codeUnitAt(p))) {
      p++;
    }
    if (p == digitsStart) return;
    final index = int.tryParse(inner.substring(digitsStart, p));
    if (index == null) return;

    final name = StringBuffer();
    int depth = 0;
    bool terminated = false;
    while (p < inner.length) {
      final c = inner[p];
      if (c == '{') {
        depth++;
        p++;
        continue;
      }
      if (c == '}') {
        if (depth > 0) depth--;
        p++;
        continue;
      }
      if (depth > 0) {
        p++;
        continue;
      }
      if (c == ';') {
        terminated = true;
        break;
      }
      if (c == '\\') {
        if (p + 4 <= inner.length && inner[p + 1] == "'") {
          final code = int.tryParse(inner.substring(p + 2, p + 4), radix: 16);
          if (code != null) name.writeCharCode(_cp1252(code));
          p += 4;
          continue;
        }
        final m = _ctrlWordPattern.matchAsPrefix(inner, p);
        if (m == null) {
          p += 2; // Control symbol: not part of the name.
          continue;
        }
        if (m.group(1) == 'u') {
          final v = int.tryParse(m.group(2) ?? '');
          if (v != null) {
            final cu = v < 0 ? v + 65536 : v;
            if (cu >= 0 && cu <= 0xFFFF) name.writeCharCode(cu);
          }
          p = _skipUnicodeFallback(inner, m.end);
          continue;
        }
        // A property word (\froman, \fcharset0, ...): anything read before it
        // was properties, not the name.
        name.clear();
        p = m.end;
        continue;
      }
      name.write(c);
      p++;
    }
    if (!terminated) return;

    final trimmed = name.toString().trim();
    if (trimmed.isEmpty) return;
    fonts[index] = trimmed;
  }

  /// Read `{\colortbl;\red255\green0\blue0;...}` into 0xRRGGBB values in
  /// declaration order. A bare `;` entry (the conventional "auto" slot at
  /// index 0) yields null so `\cf0` correctly means "no explicit color".
  static List<int?> _parseColorTable(String rtfContent) {
    final colors = <int?>[];
    const marker = '{\\colortbl';
    final start = rtfContent.indexOf(marker);
    if (start < 0) return colors;
    final end = _skipGroup(rtfContent, start + 1);
    final table = rtfContent.substring(start, end);

    int r = 0, g = 0, b = 0;
    bool seen = false;
    for (final m in _colorComponentPattern.allMatches(table)) {
      if (m.group(0) == ';') {
        colors.add(seen ? ((r << 16) | (g << 8) | b) : null);
        r = 0;
        g = 0;
        b = 0;
        seen = false;
        if (colors.length >= _maxColorTableEntries) break;
        continue;
      }
      var v = int.tryParse(m.group(2) ?? '') ?? 0;
      if (v > 255) v = 255;
      switch (m.group(1)) {
        case 'red':
          r = v;
          break;
        case 'green':
          g = v;
          break;
        case 'blue':
          b = v;
          break;
      }
      seen = true;
    }
    return colors;
  }

  /// Quill color attribute value ('#rgb', '#rrggbb', '#aarrggbb', 'rgb(...)')
  /// as 0xRRGGBB, or null when it is not a color this writer can express.
  /// Returning null must leave NO trace in the output: an attribute map that
  /// carries only unexportable values has to emit nothing at all.
  static int? _parseColorValue(Object? value) {
    if (value is! String) return null;
    var s = value.trim().toLowerCase();
    if (s.startsWith('#')) {
      s = s.substring(1);
      if (s.length == 3) {
        s = '${s[0]}${s[0]}${s[1]}${s[1]}${s[2]}${s[2]}';
      } else if (s.length == 8) {
        s = s.substring(2); // #aarrggbb: drop the alpha channel
      }
      if (s.length != 6) return null;
      return int.tryParse(s, radix: 16);
    }
    final m = _rgbFunctionPattern.firstMatch(s);
    if (m == null) return null;
    int component(int group) {
      final v = int.tryParse(m.group(group) ?? '') ?? 0;
      return v > 255 ? 255 : v;
    }

    return (component(1) << 16) | (component(2) << 8) | component(3);
  }

  /// Color for a `\cfN` / `\highlightN` index, bounds-checked: a crafted
  /// \cf99 against a two-entry table must not throw and must not paint a
  /// color the document never declared.
  static String? _colorAt(List<int?> colors, int? index) {
    if (index == null || index < 0 || index >= colors.length) return null;
    final rgb = colors[index];
    if (rgb == null) return null;
    return '#${rgb.toRadixString(16).padLeft(6, '0')}';
  }

  static bool _isDigit(int codeUnit) => codeUnit >= 0x30 && codeUnit <= 0x39;

  /// Attributes of a Delta op, tolerating a malformed (non-map) value. The
  /// exporter documents that garbage Delta never throws, but a bare cast to
  /// `Map<String, dynamic>` threw on `"attributes": 5`.
  static Map<String, dynamic> _attributesOf(Map op) {
    final raw = op['attributes'];
    return raw is Map<String, dynamic> ? raw : const <String, dynamic>{};
  }

  static void _parseRtfContent(
    String content,
    List<Map<String, dynamic>> ops,
    Map<int, String> fonts,
    List<int?> colors,
    _RtfInlineState state,
    int fieldDepth,
  ) {
    // Inline formatting is group-scoped: '{' pushes the current state and the
    // matching '}' restores it, so {\b bold} normal imports only 'bold' as
    // bold. Explicit switches (\b0, \plain) still override the stack top.
    final stack = <_RtfInlineState>[];
    int overflowDepth = 0;
    // Paragraph properties (\li, \fi, \outlinelevel) live outside the group
    // stack: Scrib's exporter closes each paragraph group before emitting
    // \par, and real producers reset them per paragraph with \pard.
    final block = _RtfBlockState();
    int paraStart = ops.length;
    // Number of the last ordered-list item accepted, so a literal "N.<tab>"
    // is only treated as a list marker when it continues a real run.
    int orderedRun = 0;
    final textBuffer = StringBuffer();

    void flushText() {
      if (textBuffer.isEmpty) return;

      final attrs = state.toAttributes();
      if (attrs.isEmpty) {
        ops.add({'insert': textBuffer.toString()});
      } else {
        ops.add({'insert': textBuffer.toString(), 'attributes': attrs});
      }
      textBuffer.clear();
    }

    void flushParagraph() {
      flushText();
      final resolved = _resolveBlockAttrs(ops, paraStart, block, orderedRun);
      final blockAttrs = resolved.$1;
      orderedRun = resolved.$2;
      if (blockAttrs == null) {
        ops.add({'insert': '\n'});
      } else {
        ops.add({'insert': '\n', 'attributes': blockAttrs});
      }
      paraStart = ops.length;
      block.reset();
    }

    int i = 0;
    while (i < content.length) {
      if (content[i] == '{') {
        i++;
        if (i < content.length && content[i] == '\\') {
          // {\*\...} is an ignorable destination (\*\generator, \*\themedata,
          // ...): the spec requires readers that don't understand it to skip
          // the whole group, otherwise its payload leaks into the note text.
          if (i + 1 < content.length && content[i + 1] == '*') {
            i = _skipGroup(content, i);
            continue;
          }
          final ctrlMatch = _groupCtrlPattern.matchAsPrefix(content, i);
          final ctrl = ctrlMatch?.group(1) ?? '';
          if (ctrl == 'fonttbl' || ctrl == 'colortbl' || ctrl == 'stylesheet' ||
              ctrl == 'info' || ctrl == 'pict') {
            // Skip entire group
            i = _skipGroup(content, i);
            continue;
          }
          if (ctrl == 'field') {
            // Hyperlink (and other) fields: parse \fldinst for the URL and
            // \fldrslt for the visible text.
            flushText();
            if (fieldDepth < _maxFieldDepth) {
              i = _parseField(
                  content, i, ops, fonts, colors, state, fieldDepth);
            } else {
              i = _skipGroup(content, i);
            }
            continue;
          }
        }
        // Ordinary group: push inline state, restored at the matching '}'.
        if (stack.length >= _maxGroupDepth) {
          overflowDepth++;
        } else {
          flushText();
          stack.add(state.copy());
        }
        continue;
      } else if (content[i] == '}') {
        i++;
        if (overflowDepth > 0) {
          overflowDepth--;
        } else if (stack.isNotEmpty) {
          flushText();
          state.setFrom(stack.removeLast());
        }
        continue;
      } else if (content[i] == '\\') {
        // Control word
        final ctrlMatch = _ctrlWordPattern.matchAsPrefix(content, i);
        if (ctrlMatch != null) {
          final word = ctrlMatch.group(1) ?? '';
          final param = ctrlMatch.group(2);
          final paramVal = param != null ? int.tryParse(param) : null;

          switch (word) {
            case 'b':
              flushText();
              state.bold = paramVal != 0;
              break;
            case 'i':
              flushText();
              state.italic = paramVal != 0;
              break;
            case 'ul':
              flushText();
              // `\ul` (no param) and `\ul1` turn underline on; `\ul0` turns it off.
              state.underline = paramVal != 0;
              break;
            case 'ulnone':
              flushText();
              state.underline = false;
              break;
            case 'u':
              // Unicode escape: paramVal is a signed 16-bit code unit.
              if (paramVal != null) {
                final cu = paramVal < 0 ? paramVal + 65536 : paramVal;
                if (cu >= 0 && cu <= 0xFFFF) {
                  textBuffer.write(String.fromCharCode(cu));
                }
              }
              break;
            case 'strike':
              flushText();
              state.strike = paramVal != 0;
              break;
            case 'sub':
              flushText();
              state.script = 'sub';
              break;
            case 'super':
              flushText();
              state.script = 'super';
              break;
            case 'nosupersub':
              flushText();
              state.script = null;
              break;
            case 'f':
              flushText();
              if (paramVal != null && fonts.containsKey(paramVal)) {
                state.font = fonts[paramVal];
              }
              break;
            case 'fs':
              flushText();
              // Clamped: an unvalidated \fs0 or \fs2000000000 became a live
              // Quill size attribute that the editor then laid out against.
              // \fs2..\fs800 covers 1pt to 400pt.
              if (paramVal != null && paramVal >= 2 && paramVal <= 800) {
                state.size = paramVal ~/ 2; // RTF font size is in half-points
              }
              break;
            case 'cf':
              flushText();
              state.color = _colorAt(colors, paramVal);
              break;
            case 'highlight':
            case 'chcbpat':
              flushText();
              state.background = _colorAt(colors, paramVal);
              break;
            case 'par':
              flushParagraph();
              break;
            case 'line':
              textBuffer.write('\n');
              break;
            case 'tab':
              textBuffer.write('\t');
              break;
            case 'li':
              block.leftIndent = paramVal ?? 0;
              break;
            case 'fi':
              block.firstLineIndent = paramVal ?? 0;
              break;
            case 'outlinelevel':
              block.outlineLevel = paramVal;
              break;
            case 'pard':
              block.reset();
              break;
            case 'plain':
              flushText();
              state.bold = false;
              state.italic = false;
              state.underline = false;
              state.strike = false;
              state.script = null;
              state.font = null;
              state.size = null;
              state.color = null;
              state.background = null;
              break;
          }

          i = ctrlMatch.end;
          // A \uN escape is followed by \ucN fallback characters (default 1)
          // for readers that can't render Unicode. Skip one fallback unit.
          if (word == 'u') {
            i = _skipUnicodeFallback(content, i);
          }
          continue;
        }

        // Escaped characters
        if (i + 1 < content.length) {
          final nextChar = content[i + 1];
          if (nextChar == '\\' || nextChar == '{' || nextChar == '}') {
            textBuffer.write(nextChar);
            i += 2;
            continue;
          }
          if (nextChar == '\'') {
            // Hex character. The escape is exactly `\'XX` (4 chars); the bounds
            // check must allow it to sit flush against end-of-string.
            if (i + 4 <= content.length) {
              final hex = content.substring(i + 2, i + 4);
              final code = int.tryParse(hex, radix: 16);
              if (code != null) {
                textBuffer.write(String.fromCharCode(_cp1252(code)));
              }
              i += 4;
              continue;
            }
          }
          if (nextChar == '~') {
            textBuffer.write(' '); // non-breaking space
            i += 2;
            continue;
          }
          // Unknown control symbol (\*, \-, \_, ...): consume both characters
          // so the symbol never leaks into the note text.
          i += 2;
          continue;
        }
        i++;
      } else if (content[i] == '\n' || content[i] == '\r') {
        // Skip literal newlines in RTF (they're whitespace)
        i++;
      } else {
        textBuffer.write(content[i]);
        i++;
      }
    }

    flushText();
  }

  /// Skip a group whose opening '{' has already been consumed ([i] points just
  /// inside it). Returns the index just past the matching '}'. Escaped
  /// characters (\{, \}, \\) don't affect the depth count. Always advances,
  /// so malformed input cannot loop forever.
  static int _skipGroup(String content, int i) {
    int depth = 1;
    while (i < content.length && depth > 0) {
      final c = content[i];
      if (c == '\\') {
        i += 2;
        continue;
      }
      if (c == '{') depth++;
      if (c == '}') depth--;
      i++;
    }
    // A backslash on the last character steps i past the end; callers pass the
    // result straight to substring, and a truncated font table used to abort
    // the whole import with a RangeError.
    return i > content.length ? content.length : i;
  }

  /// Parse a {\field ...} group. [i] points at the '\field' control word just
  /// inside the group. Extracts the HYPERLINK target from \fldinst (if any,
  /// and only if its scheme passes the shared allowlist) and parses the
  /// \fldrslt display text recursively with the link applied. Returns the
  /// index just past the field group.
  static int _parseField(
      String content,
      int i,
      List<Map<String, dynamic>> ops,
      Map<int, String> fonts,
      List<int?> colors,
      _RtfInlineState state,
      int fieldDepth) {
    final end = _skipGroup(content, i);
    final body = content.substring(i, end > i ? end - 1 : i);

    String? url;
    final quoted = _hyperlinkQuotedPattern.firstMatch(body);
    if (quoted != null) {
      url = _decodeFieldText(quoted.group(1) ?? '');
    } else {
      final bare = _hyperlinkBarePattern.firstMatch(body);
      if (bare != null) {
        url = _decodeFieldText(bare.group(1) ?? '');
      }
    }

    final rsltIdx = body.indexOf('\\fldrslt');
    if (rsltIdx >= 0) {
      int j = rsltIdx + '\\fldrslt'.length;
      if (j < body.length && body[j] == ' ') j++;
      final rsltEnd = _skipGroup(body, j);
      final inner = body.substring(j, rsltEnd > j ? rsltEnd - 1 : j);
      final childState = state.copy();
      // Same allowlist as the link dialog, the launch path and the export
      // path: a note must never carry a javascript:, file: or UNC link,
      // including one smuggled in via a crafted .rtf file.
      if (url != null && url.isNotEmpty && isSafeLaunchUrl(url)) {
        childState.link = url;
      }
      _parseRtfContent(inner, ops, fonts, colors, childState, fieldDepth + 1);
    }
    return end;
  }

  /// Decode the minimal RTF escapes that can appear inside a field
  /// instruction (\\, \{, \}, \'XX hex bytes, \uN unicode).
  static String _decodeFieldText(String raw) {
    if (!raw.contains('\\')) return raw;
    final buf = StringBuffer();
    int i = 0;
    while (i < raw.length) {
      final c = raw[i];
      if (c != '\\') {
        buf.write(c);
        i++;
        continue;
      }
      if (i + 1 >= raw.length) break;
      final next = raw[i + 1];
      if (next == '\\' || next == '{' || next == '}') {
        buf.write(next);
        i += 2;
        continue;
      }
      if (next == '\'' && i + 4 <= raw.length) {
        final code = int.tryParse(raw.substring(i + 2, i + 4), radix: 16);
        if (code != null) buf.write(String.fromCharCode(_cp1252(code)));
        i += 4;
        continue;
      }
      final m = _ctrlWordPattern.matchAsPrefix(raw, i);
      if (m != null) {
        if (m.group(1) == 'u') {
          final v = int.tryParse(m.group(2) ?? '');
          if (v != null) {
            final cu = v < 0 ? v + 65536 : v;
            if (cu >= 0 && cu <= 0xFFFF) buf.write(String.fromCharCode(cu));
          }
          i = _skipUnicodeFallback(raw, m.end);
          continue;
        }
        i = m.end;
        continue;
      }
      i += 2;
    }
    return buf.toString();
  }

  /// Decide the block attributes for the paragraph occupying
  /// ops[paraStart..end] based on the paragraph properties seen since the
  /// last \par/\pard. Recognizes Scrib's own export markers (and Word's
  /// equivalents) so block structure survives a round-trip:
  /// - \outlinelevelN        -> header N+1 (bold/size the exporter added are
  ///                            stripped back off the text runs)
  /// - hanging indent + '• ' / '· ' marker -> bullet list
  /// - hanging indent + '[x] ' / '[ ] '    -> checklist
  /// - hanging indent + 'N. '              -> ordered list
  /// - \li720 with no hanging indent       -> blockquote
  /// Markers are removed from the text so they don't duplicate Quill's own
  /// list rendering. Returns the attributes and the ordered-list run counter
  /// to carry into the next paragraph.
  static (Map<String, dynamic>?, int) _resolveBlockAttrs(
      List<Map<String, dynamic>> ops,
      int paraStart,
      _RtfBlockState block,
      int orderedRun) {
    final level = block.outlineLevel;
    if (level != null && level >= 0 && level < _headerHalfPointSizes.length) {
      _stripHeaderStyles(ops, paraStart, level + 1);
      return ({'header': level + 1}, 0);
    }
    if (block.leftIndent > 0 && block.firstLineIndent < 0) {
      final listType = _stripListMarker(ops, paraStart, orderedRun + 1);
      if (listType == 'ordered') return ({'list': listType}, orderedRun + 1);
      if (listType != null) return ({'list': listType}, 0);
      return (null, 0);
    }
    if (block.leftIndent == 720 && block.firstLineIndent == 0) {
      return ({'blockquote': true}, 0);
    }
    return (null, 0);
  }

  /// Remove the bold flag and the header-derived size from a header
  /// paragraph's text runs. The exporter adds `\b\fs<size>` to the whole
  /// paragraph for RTF renderers; importing them as inline attributes would
  /// double-style the header in Quill.
  static void _stripHeaderStyles(
      List<Map<String, dynamic>> ops, int paraStart, int level) {
    final headerSize = _headerHalfPointSizes[level - 1] ~/ 2;
    for (int k = paraStart; k < ops.length; k++) {
      final attrs = ops[k]['attributes'];
      if (attrs is! Map<String, dynamic>) continue;
      if (attrs['bold'] == true) attrs.remove('bold');
      if (attrs['size'] == headerSize) attrs.remove('size');
      if (attrs.isEmpty) ops[k].remove('attributes');
    }
  }

  /// If the paragraph's first text run starts with a recognized list marker,
  /// strip the marker and return the Quill list type; otherwise return null.
  ///
  /// [expectedNumber] is the number an ordered marker must carry to be treated
  /// as one. A hanging indent plus a literal `N.<tab>` is exactly what Word
  /// produces for a MANUALLY numbered paragraph (contracts, specs), and
  /// stripping it deleted user text that Quill then renumbered from 1, so an
  /// ordered marker only counts when it continues a run that started at 1.
  static String? _stripListMarker(
      List<Map<String, dynamic>> ops, int paraStart, int expectedNumber) {
    if (paraStart >= ops.length) return null;
    final first = ops[paraStart];
    final text = first['insert'];
    if (text is! String) return null;

    String? type;
    int markerLen = 0;
    if (text.startsWith('•\t') || text.startsWith('·\t')) {
      // \'95 (WordPad/Scrib bullet) or \'b7 (Word's Symbol-font bullet)
      type = 'bullet';
      markerLen = 2;
    } else if (text.startsWith('[x]\t')) {
      type = 'checked';
      markerLen = 4;
    } else if (text.startsWith('[ ]\t')) {
      type = 'unchecked';
      markerLen = 4;
    } else {
      final m = _orderedMarkerPattern.matchAsPrefix(text);
      if (m != null && int.tryParse(m.group(1) ?? '') == expectedNumber) {
        type = 'ordered';
        markerLen = m.end;
      }
    }
    if (type == null) return null;

    final rest = text.substring(markerLen);
    if (rest.isEmpty) {
      ops.removeAt(paraStart);
    } else {
      ops[paraStart] = Map<String, dynamic>.from(first)..['insert'] = rest;
    }
    return type;
  }

  /// Advance past the single fallback character that follows a `\uN` escape
  /// (the `\ucN` substitution count defaults to 1). The fallback may be a
  /// literal char, a `\'XX` hex byte, or another control word.
  static int _skipUnicodeFallback(String content, int i) {
    if (i >= content.length) return i;
    if (content[i] == '\\') {
      final fb = _unicodeFallbackPattern.matchAsPrefix(content, i);
      if (fb != null) return fb.end;
      return i + 1;
    }
    return i + 1;
  }

  /// Map a single RTF `\'XX` byte to a Unicode code point. Bytes 0x00-0x7F and
  /// 0xA0-0xFF are identical to Latin-1; the 0x80-0x9F range is the Windows
  /// cp1252 "smart punctuation" block that differs from Latin-1 (e.g. 0x95 is
  /// the bullet U+2022, 0x92 the right single quote U+2019).
  static int _cp1252(int b) {
    if (b < 0x80 || b > 0x9F) return b;
    const table = <int, int>{
      0x80: 0x20AC, 0x82: 0x201A, 0x83: 0x0192, 0x84: 0x201E, 0x85: 0x2026,
      0x86: 0x2020, 0x87: 0x2021, 0x88: 0x02C6, 0x89: 0x2030, 0x8A: 0x0160,
      0x8B: 0x2039, 0x8C: 0x0152, 0x8E: 0x017D, 0x91: 0x2018, 0x92: 0x2019,
      0x93: 0x201C, 0x94: 0x201D, 0x95: 0x2022, 0x96: 0x2013, 0x97: 0x2014,
      0x98: 0x02DC, 0x99: 0x2122, 0x9A: 0x0161, 0x9B: 0x203A, 0x9C: 0x0153,
      0x9E: 0x017E, 0x9F: 0x0178,
    };
    return table[b] ?? b;
  }

  /// Opening group for a run's inline formatting, or '' when this writer has
  /// nothing to say about the run. The caller closes it iff it is non-empty.
  ///
  /// The control words are built FIRST for exactly that reason: the old form
  /// opened '{' for any non-empty attribute map and then wrote the delimiter
  /// space unconditionally, so an attribute the writer does not export (an
  /// alignment, an indent) turned into a literal space in the user's document
  /// on every save. Color and highlight are exported properly now, against
  /// the \colortbl deltaToRtf emits.
  static String _inlineFormatting(
      Map<String, dynamic> attrs, List<String> fontList, List<int> colorList) {
    if (attrs.isEmpty) return '';

    final buf = StringBuffer();
    if (attrs['bold'] == true) buf.write('\\b');
    if (attrs['italic'] == true) buf.write('\\i');
    if (attrs['underline'] == true) buf.write('\\ul');
    if (attrs['strike'] == true) buf.write('\\strike');
    if (attrs['script'] == 'sub') buf.write('\\sub');
    if (attrs['script'] == 'super') buf.write('\\super');
    final font = attrs['font'];
    if (font is String) {
      final fontIndex = fontList.indexOf(font);
      if (fontIndex >= 0) buf.write('\\f$fontIndex');
    }
    final size = attrs['size'];
    if (size is num && size.isFinite && size > 0) {
      // Bounded before .round(): a huge double throws there, and \fs is a
      // half-point measure so 400pt is already past any real use.
      final half = size >= 400 ? 800 : (size * 2).round();
      buf.write('\\fs$half');
    }
    final color = _parseColorValue(attrs['color']);
    if (color != null) {
      final idx = colorList.indexOf(color);
      if (idx >= 0) buf.write('\\cf${idx + 1}');
    }
    final background = _parseColorValue(attrs['background']);
    if (background != null) {
      final idx = colorList.indexOf(background);
      if (idx >= 0) buf.write('\\highlight${idx + 1}');
    }

    if (buf.isEmpty) return '';
    return '{$buf ';
  }

  static String _blockFormattingOpen(
      Map<String, dynamic> attrs, int orderedNumber) {
    if (attrs.containsKey('header')) {
      final level = attrs['header'];
      if (level is int && level >= 1 && level <= 6) {
        // \outlinelevelN carries the heading level so the importer (and
        // Word's outline view) can reconstruct it; WordPad ignores it.
        return '{\\outlinelevel${level - 1}\\b\\fs${_headerHalfPointSizes[level - 1]} ';
      }
    }
    if (attrs.containsKey('blockquote') && attrs['blockquote'] == true) {
      return '{\\li720 ';
    }
    if (attrs.containsKey('list')) {
      final listType = attrs['list'];
      if (listType == 'bullet') return '{\\li720\\fi-360 \\\'95\\tab ';
      if (listType == 'ordered') {
        return '{\\li720\\fi-360 $orderedNumber.\\tab ';
      }
      // Checklists export as [x] / [ ] markers. Every branch that returns a
      // non-empty string must open exactly one '{': the caller closes what
      // this opened, and nothing else.
      if (listType == 'checked') return '{\\li720\\fi-360 [x]\\tab ';
      if (listType == 'unchecked') return '{\\li720\\fi-360 [ ]\\tab ';
      return '{';
    }
    return '';
  }

  static String _wrapRtf(String content,
      {String fontTable = '{\\fonttbl{\\f0\\fswiss Times New Roman;}}',
      String colorTable = ''}) {
    // \ansicpg1252 declares the code page the exporter's raw \'XX bytes (the
    // \'95 list bullet) are written in; without it a reader is free to guess.
    final tables =
        colorTable.isEmpty ? fontTable : '$fontTable\n$colorTable';
    return '{\\rtf1\\ansi\\ansicpg1252\\deff0\n'
        '$tables\n'
        '$content\n'
        '}';
  }

  /// Escape a URL for embedding inside a quoted HYPERLINK field instruction.
  /// A double quote would terminate the quoted string, so it is
  /// percent-encoded before the normal RTF escaping.
  static String _escapeFieldUrl(String url) {
    return _escapeRtf(url.replaceAll('"', '%22'));
  }

  static String _escapeRtf(String text) {
    final buf = StringBuffer();
    for (final codeUnit in text.codeUnits) {
      if (codeUnit == 0x5C) { // backslash
        buf.write('\\\\');
      } else if (codeUnit == 0x7B) { // {
        buf.write('\\{');
      } else if (codeUnit == 0x7D) { // }
        buf.write('\\}');
      } else if (codeUnit == 0x09) { // tab
        // A raw 0x09 is whitespace to an RTF reader, so an exported tab was
        // silently lost. The trailing space is the control-word delimiter and
        // readers (including this one) consume it.
        buf.write('\\tab ');
      } else if (codeUnit > 127) {
        // RTF \uN takes a SIGNED 16-bit integer: code units above 32767 must be
        // emitted as N-65536. Iterating codeUnits emits each UTF-16 unit, so
        // astral characters (emoji etc.) come through as their two surrogate
        // halves — exactly how RTF represents them as a pair of \uN escapes.
        final signed = codeUnit > 32767 ? codeUnit - 65536 : codeUnit;
        buf.write('\\u$signed?');
      } else {
        buf.writeCharCode(codeUnit);
      }
    }
    return buf.toString();
  }
}

/// Mutable inline character formatting during an RTF parse. An instance is
/// pushed at every '{' and restored at the matching '}' so formatting cannot
/// bleed past its enclosing group.
class _RtfInlineState {
  bool bold = false;
  bool italic = false;
  bool underline = false;
  bool strike = false;
  String? script; // 'sub' | 'super'
  String? font;
  int? size;
  String? link;
  String? color; // '#rrggbb'
  String? background; // '#rrggbb'

  _RtfInlineState copy() {
    return _RtfInlineState()
      ..bold = bold
      ..italic = italic
      ..underline = underline
      ..strike = strike
      ..script = script
      ..font = font
      ..size = size
      ..link = link
      ..color = color
      ..background = background;
  }

  void setFrom(_RtfInlineState other) {
    bold = other.bold;
    italic = other.italic;
    underline = other.underline;
    strike = other.strike;
    script = other.script;
    font = other.font;
    size = other.size;
    link = other.link;
    color = other.color;
    background = other.background;
  }

  /// Quill attribute map for the current state. Keys match what the toolbar
  /// applies (Attribute.bold/italic/underline/strikeThrough/script/font/
  /// size/link/color/background).
  Map<String, dynamic> toAttributes() {
    final attrs = <String, dynamic>{};
    if (bold) attrs['bold'] = true;
    if (italic) attrs['italic'] = true;
    if (underline) attrs['underline'] = true;
    if (strike) attrs['strike'] = true;
    if (script != null) attrs['script'] = script;
    if (font != null) attrs['font'] = font;
    if (size != null) attrs['size'] = size;
    if (link != null) attrs['link'] = link;
    if (color != null) attrs['color'] = color;
    if (background != null) attrs['background'] = background;
    return attrs;
  }
}

/// Paragraph-level properties pending for the current paragraph during an RTF
/// parse; reset at every \par and \pard.
class _RtfBlockState {
  int leftIndent = 0; // \liN (twips)
  int firstLineIndent = 0; // \fiN (twips; negative = hanging indent)
  int? outlineLevel; // \outlinelevelN (0-based header level)

  void reset() {
    leftIndent = 0;
    firstLineIndent = 0;
    outlineLevel = null;
  }
}
