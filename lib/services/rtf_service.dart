import 'dart:convert';

/// Converts between Quill Delta JSON and RTF format.
///
/// Supports: bold, italic, underline, strikethrough, font family, font size,
/// headers, bullet lists, numbered lists, and block quotes.
///
/// RTF parsing is best-effort. The parser handles the subset of RTF produced
/// by Word, WordPad, and LibreOffice for simple documents — complex features
/// (nested tables, images, styles, Unicode \uN escapes beyond BMP, custom
/// color tables) pass through as stripped text. For a byte-perfect RTF
/// exchange, use a dedicated library in a future revision.
///
/// All methods are static — RtfService carries no state.
class RtfService {
  RtfService._();

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

    // First pass: collect all fonts used
    for (final op in ops) {
      if (op is Map && op.containsKey('attributes')) {
        final attrs = op['attributes'] as Map<String, dynamic>?;
        final font = attrs?['font'];
        if (font is String) {
          fonts.add(font);
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

    // Second pass: group ops into paragraphs.
    // In Quill Delta, block attributes (header, list, blockquote) are on the
    // '\n' op that *ends* the paragraph — not on the text ops before it.
    // We buffer each paragraph's inline content and flush it with the block
    // formatting prepended when we encounter the terminating '\n'.
    final content = StringBuffer();
    final paraBuffer = StringBuffer();
    bool paraHasContent = false;

    void flushParagraph(Map<String, dynamic> blockAttrs) {
      final open = _blockFormattingOpen(blockAttrs);
      final close = _blockFormattingClose(blockAttrs);
      content.write(open);
      content.write(paraBuffer.toString());
      content.write(close);
      content.write('\\par\n');
      paraBuffer.clear();
      paraHasContent = false;
    }

    for (final op in ops) {
      if (op is! Map || !op.containsKey('insert')) continue;

      final insert = op['insert'];
      if (insert is! String) continue;

      final attrs = (op['attributes'] as Map<String, dynamic>?) ?? {};

      if (insert == '\n') {
        // End of paragraph — emit buffered content with block formatting first
        flushParagraph(attrs);
      } else {
        // Split by embedded newlines (plain newlines inside a text run become
        // separate unstyled paragraphs)
        final lines = insert.split('\n');
        for (int j = 0; j < lines.length; j++) {
          if (lines[j].isNotEmpty) {
            paraBuffer.write(_inlineFormatting(attrs, fontList));
            paraBuffer.write(_escapeRtf(lines[j]));
            paraBuffer.write(_inlineFormattingClose(attrs));
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

    return _wrapRtf(content.toString(), fontTable: fontTable.toString());
  }

  /// Parse RTF string to Quill Delta JSON string
  static String rtfToDelta(String rtfContent) {
    if (rtfContent.isEmpty || !rtfContent.startsWith('{\\rtf')) {
      // Not RTF, treat as plain text
      return jsonEncode([
        {'insert': '$rtfContent\n'}
      ]);
    }

    final ops = <Map<String, dynamic>>[];
    final fonts = <int, String>{};

    // Parse font table
    final fontTableMatch = RegExp(r'\{\\fonttbl(.*?)\}(?=\s*\{|[^}])').firstMatch(rtfContent);
    if (fontTableMatch != null) {
      final fontTableStr = fontTableMatch.group(0) ?? '';
      final fontEntries = RegExp(r'\{\\f(\d+)[^}]*\s+([^;]+);\}').allMatches(fontTableStr);
      for (final entry in fontEntries) {
        final index = int.tryParse(entry.group(1) ?? '');
        final name = entry.group(2)?.trim();
        if (index != null && name != null) {
          fonts[index] = name;
        }
      }
    }

    // Strip header - find content after font/color tables
    var content = rtfContent;
    // Remove the outer {\rtf1...} wrapper
    if (content.startsWith('{\\rtf')) {
      // Find the end of the header section (after all tables)
      int depth = 0;
      int headerEnd = 0;
      bool inHeader = true;

      for (int i = 0; i < content.length; i++) {
        if (content[i] == '{') {
          depth++;
        } else if (content[i] == '}') {
          depth--;
          if (depth == 0) {
            // End of document
            content = content.substring(headerEnd, i);
            break;
          }
        }

        // Skip font table, color table, etc.
        if (inHeader && depth == 1) {
          if (i > 0 && content[i] != '{' && content[i] != '\\') {
            // We've passed the header tables
            inHeader = false;
            headerEnd = i;
          } else if (content[i] == '\\') {
            // Skip header control words
            final ctrlMatch = RegExp(r'\\[a-z]+\d*\s?').matchAsPrefix(content, i);
            if (ctrlMatch != null) {
              // Check if this is a known header control word
              final ctrl = ctrlMatch.group(0) ?? '';
              if (ctrl.startsWith('\\rtf') || ctrl.startsWith('\\ansi') ||
                  ctrl.startsWith('\\deff') || ctrl.startsWith('\\viewkind')) {
                i = ctrlMatch.end - 1;
                headerEnd = i + 1;
                continue;
              }
              inHeader = false;
              headerEnd = i;
            }
          }
        }
      }
    }

    // Parse RTF content into ops
    _parseRtfContent(content, ops, fonts);

    // Ensure document ends with newline
    if (ops.isEmpty || !(ops.last['insert'] as String).endsWith('\n')) {
      ops.add({'insert': '\n'});
    }

    return jsonEncode(ops);
  }

  static void _parseRtfContent(String content, List<Map<String, dynamic>> ops, Map<int, String> fonts) {
    bool bold = false;
    bool italic = false;
    bool underline = false;
    bool strike = false;
    String? currentFont;
    int? fontSize;
    final textBuffer = StringBuffer();

    void flushText() {
      if (textBuffer.isEmpty) return;

      final attrs = <String, dynamic>{};
      if (bold) attrs['bold'] = true;
      if (italic) attrs['italic'] = true;
      if (underline) attrs['underline'] = true;
      if (strike) attrs['strike'] = true;
      if (currentFont != null) attrs['font'] = currentFont;
      if (fontSize != null) attrs['size'] = fontSize;

      if (attrs.isEmpty) {
        ops.add({'insert': textBuffer.toString()});
      } else {
        ops.add({'insert': textBuffer.toString(), 'attributes': attrs});
      }
      textBuffer.clear();
    }

    int i = 0;
    while (i < content.length) {
      if (content[i] == '{') {
        // Skip groups we don't understand
        int depth = 1;
        i++;
        // Check if it's a known group
        if (i < content.length && content[i] == '\\') {
          final ctrlMatch = RegExp(r'\\([a-z]+)').matchAsPrefix(content, i);
          final ctrl = ctrlMatch?.group(1) ?? '';
          if (ctrl == 'fonttbl' || ctrl == 'colortbl' || ctrl == 'stylesheet' ||
              ctrl == 'info' || ctrl == 'pict') {
            // Skip entire group
            while (i < content.length && depth > 0) {
              if (content[i] == '{') depth++;
              if (content[i] == '}') depth--;
              i++;
            }
            continue;
          }
        }
        // For other groups, process content inside
        continue;
      } else if (content[i] == '}') {
        i++;
        continue;
      } else if (content[i] == '\\') {
        // Control word
        final ctrlMatch = RegExp(r'\\([a-z]+)(-?\d+)?\s?').matchAsPrefix(content, i);
        if (ctrlMatch != null) {
          final word = ctrlMatch.group(1) ?? '';
          final param = ctrlMatch.group(2);
          final paramVal = param != null ? int.tryParse(param) : null;

          switch (word) {
            case 'b':
              flushText();
              bold = paramVal != 0;
              break;
            case 'i':
              flushText();
              italic = paramVal != 0;
              break;
            case 'ul':
              flushText();
              // `\ul` (no param) and `\ul1` turn underline on; `\ul0` turns it off.
              underline = paramVal != 0;
              break;
            case 'ulnone':
              flushText();
              underline = false;
              break;
            case 'u':
              // Unicode escape: paramVal is a signed 16-bit code unit.
              flushText();
              if (paramVal != null) {
                final cu = paramVal < 0 ? paramVal + 65536 : paramVal;
                if (cu >= 0 && cu <= 0xFFFF) {
                  textBuffer.write(String.fromCharCode(cu));
                }
              }
              break;
            case 'strike':
              flushText();
              strike = paramVal != 0;
              break;
            case 'f':
              flushText();
              if (paramVal != null && fonts.containsKey(paramVal)) {
                currentFont = fonts[paramVal];
              }
              break;
            case 'fs':
              flushText();
              if (paramVal != null) {
                fontSize = paramVal ~/ 2; // RTF font size is in half-points
              }
              break;
            case 'par':
              flushText();
              ops.add({'insert': '\n'});
              break;
            case 'line':
              textBuffer.write('\n');
              break;
            case 'tab':
              textBuffer.write('\t');
              break;
            case 'plain':
              flushText();
              bold = false;
              italic = false;
              underline = false;
              strike = false;
              currentFont = null;
              fontSize = null;
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

  /// Advance past the single fallback character that follows a `\uN` escape
  /// (the `\ucN` substitution count defaults to 1). The fallback may be a
  /// literal char, a `\'XX` hex byte, or another control word.
  static int _skipUnicodeFallback(String content, int i) {
    if (i >= content.length) return i;
    if (content[i] == '\\') {
      final fb = RegExp(r"\\'[0-9a-fA-F]{2}|\\[a-z]+-?\d*\s?")
          .matchAsPrefix(content, i);
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

  static String _inlineFormatting(Map<String, dynamic> attrs, List<String> fontList) {
    if (attrs.isEmpty) return '';

    final buf = StringBuffer('{');
    if (attrs.containsKey('bold') && attrs['bold'] == true) buf.write('\\b');
    if (attrs.containsKey('italic') && attrs['italic'] == true) buf.write('\\i');
    if (attrs.containsKey('underline') && attrs['underline'] == true) buf.write('\\ul');
    if (attrs.containsKey('strike') && attrs['strike'] == true) buf.write('\\strike');
    if (attrs['script'] == 'sub') buf.write('\\sub');
    if (attrs['script'] == 'super') buf.write('\\super');
    final font = attrs['font'];
    if (font is String) {
      final fontIndex = fontList.indexOf(font);
      if (fontIndex >= 0) buf.write('\\f$fontIndex');
    }
    if (attrs.containsKey('size')) {
      final size = attrs['size'];
      if (size is num) {
        buf.write('\\fs${(size * 2).round()}'); // RTF uses half-points
      }
    }
    buf.write(' ');
    return buf.toString();
  }

  static String _inlineFormattingClose(Map<String, dynamic> attrs) {
    if (attrs.isEmpty) return '';
    return '}';
  }

  static String _blockFormattingOpen(Map<String, dynamic> attrs) {
    if (attrs.containsKey('header')) {
      final level = attrs['header'];
      if (level is int && level >= 1 && level <= 6) {
        final sizes = [48, 40, 32, 28, 24, 20];
        return '{\\b\\fs${sizes[level - 1]} ';
      }
    }
    if (attrs.containsKey('blockquote') && attrs['blockquote'] == true) {
      return '{\\li720 ';
    }
    if (attrs.containsKey('list')) {
      final listType = attrs['list'];
      if (listType == 'bullet') return '{\\li720\\fi-360 \\\'95\\tab ';
      if (listType == 'ordered') return '{\\li720\\fi-360 ';
      // Checklists export as [x] / [ ] markers. These branches must return a
      // '{' like the others: _blockFormattingClose emits '}' for ANY list
      // line, so a missing open brace here would corrupt the RTF.
      if (listType == 'checked') return '{\\li720\\fi-360 [x]\\tab ';
      if (listType == 'unchecked') return '{\\li720\\fi-360 [ ]\\tab ';
      return '{';
    }
    return '';
  }

  static String _blockFormattingClose(Map<String, dynamic> attrs) {
    if (attrs.containsKey('header') ||
        attrs.containsKey('blockquote') ||
        attrs.containsKey('list')) {
      return '}';
    }
    return '';
  }

  static String _wrapRtf(String content, {String fontTable = '{\\fonttbl{\\f0\\fswiss Times New Roman;}}'}) {
    return '{\\rtf1\\ansi\\deff0\n'
        '$fontTable\n'
        '$content\n'
        '}';
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
