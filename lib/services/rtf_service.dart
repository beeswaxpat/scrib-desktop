import 'dart:convert';

/// Converts between Quill Delta JSON and RTF format.
///
/// Supports: bold, italic, underline, strikethrough, sub/superscript,
/// hyperlinks (as `{\field{\*\fldinst HYPERLINK ...}}` fields), font family,
/// font size, headers, bullet lists, numbered lists, checklists, and block
/// quotes. Inline formatting is group-scoped on import (a `}` restores the
/// state that was active at the matching `{`), unknown `{\*\...}` destination
/// groups are skipped per the RTF spec, and Scrib's own block markers
/// (bullet/number/checkbox glyphs plus `\outlinelevelN` for headers) are
/// recognized on import so Scrib -> RTF -> Scrib round-trips block structure.
///
/// RTF parsing is best-effort. The parser handles the subset of RTF produced
/// by Word, WordPad, and LibreOffice for simple documents — complex features
/// (nested tables, images, styles, custom color tables) pass through as
/// stripped text. For a byte-perfect RTF exchange, use a dedicated library in
/// a future revision.
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

  // Compiled once — the parser hits these on every token, so per-loop
  // RegExp construction was a measurable cost on large files.
  static final RegExp _ctrlWordPattern = RegExp(r'\\([a-z]+)(-?\d+)?\s?');
  static final RegExp _groupCtrlPattern = RegExp(r'\\([a-z]+)');
  static final RegExp _headerCtrlPattern = RegExp(r'\\[a-z]+\d*\s?');
  static final RegExp _unicodeFallbackPattern =
      RegExp(r"\\'[0-9a-fA-F]{2}|\\[a-z]+-?\d*\s?");
  // Lazy up to the first whitespace that starts a backslash-free run, so
  // multi-word names ('Times New Roman') survive (the old greedy form kept
  // only the last word) while `\fbidi \froman Name` still yields 'Name'.
  static final RegExp _fontEntryPattern =
      RegExp(r'\{\\f(\d+)[^}]*?\s([^;{}\\]+);\}');
  static final RegExp _hyperlinkQuotedPattern = RegExp(r'HYPERLINK\s+"([^"]*)"');
  static final RegExp _hyperlinkBarePattern =
      RegExp(r'HYPERLINK\s+([^\s"{}\\]+)');
  static final RegExp _orderedMarkerPattern = RegExp(r'^\d{1,4}\.\t');

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
        final link = attrs['link'];
        // The link itself rides in the field instruction; the visible run
        // keeps its other inline formatting inside \fldrslt.
        final inlineAttrs = link is String
            ? (Map<String, dynamic>.from(attrs)..remove('link'))
            : attrs;
        for (int j = 0; j < lines.length; j++) {
          if (lines[j].isNotEmpty) {
            if (link is String) {
              paraBuffer.write(
                  '{\\field{\\*\\fldinst{HYPERLINK "${_escapeFieldUrl(link)}"}}{\\fldrslt ');
            }
            paraBuffer.write(_inlineFormatting(inlineAttrs, fontList));
            paraBuffer.write(_escapeRtf(lines[j]));
            paraBuffer.write(_inlineFormattingClose(inlineAttrs));
            if (link is String) {
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

    return _wrapRtf(content.toString(), fontTable: fontTable.toString());
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
            final ctrlMatch = _headerCtrlPattern.matchAsPrefix(content, i);
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
    _parseRtfContent(content, ops, fonts, _RtfInlineState(), 0);

    // Ensure document ends with newline
    if (ops.isEmpty || !(ops.last['insert'] as String).endsWith('\n')) {
      ops.add({'insert': '\n'});
    }

    return jsonEncode(ops);
  }

  /// Extract the full font table with a brace-balanced scan. A regex with a
  /// lazy quantifier stopped at the first entry's closing brace, dropping
  /// every font except \f0 in multi-font tables.
  static Map<int, String> _parseFontTable(String rtfContent) {
    final fonts = <int, String>{};
    final start = rtfContent.indexOf('{\\fonttbl');
    if (start < 0) return fonts;
    final end = _skipGroup(rtfContent, start + 1);
    final table = rtfContent.substring(start, end);
    for (final entry in _fontEntryPattern.allMatches(table)) {
      final index = int.tryParse(entry.group(1) ?? '');
      final name = entry.group(2)?.trim();
      if (index != null && name != null) {
        fonts[index] = name;
      }
    }
    return fonts;
  }

  static void _parseRtfContent(
    String content,
    List<Map<String, dynamic>> ops,
    Map<int, String> fonts,
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
      final blockAttrs = _resolveBlockAttrs(ops, paraStart, block);
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
              i = _parseField(content, i, ops, fonts, state, fieldDepth);
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
              if (paramVal != null) {
                state.size = paramVal ~/ 2; // RTF font size is in half-points
              }
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
            textBuffer.write(' '); // non-breaking space
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
    return i;
  }

  /// Parse a {\field ...} group. [i] points at the '\field' control word just
  /// inside the group. Extracts the HYPERLINK target from \fldinst (if any,
  /// and only if its scheme is http/https/mailto) and parses the \fldrslt
  /// display text recursively with the link applied. Returns the index just
  /// past the field group.
  static int _parseField(String content, int i, List<Map<String, dynamic>> ops,
      Map<int, String> fonts, _RtfInlineState state, int fieldDepth) {
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
      if (url != null && url.isNotEmpty && _isSafeLinkUrl(url)) {
        childState.link = url;
      }
      _parseRtfContent(inner, ops, fonts, childState, fieldDepth + 1);
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

  /// Same allowlist as the link dialog and the launch path (format_utils):
  /// a note must never carry a javascript:, file:, or other active-scheme
  /// link, including one smuggled in via a crafted .rtf file.
  static bool _isSafeLinkUrl(String url) {
    final scheme = Uri.tryParse(url.trim())?.scheme.toLowerCase() ?? '';
    return scheme == 'http' || scheme == 'https' || scheme == 'mailto';
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
  /// list rendering.
  static Map<String, dynamic>? _resolveBlockAttrs(
      List<Map<String, dynamic>> ops, int paraStart, _RtfBlockState block) {
    final level = block.outlineLevel;
    if (level != null && level >= 0 && level < _headerHalfPointSizes.length) {
      _stripHeaderStyles(ops, paraStart, level + 1);
      return {'header': level + 1};
    }
    if (block.leftIndent > 0 && block.firstLineIndent < 0) {
      final listType = _stripListMarker(ops, paraStart);
      if (listType != null) return {'list': listType};
      return null;
    }
    if (block.leftIndent == 720 && block.firstLineIndent == 0) {
      return {'blockquote': true};
    }
    return null;
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
  static String? _stripListMarker(
      List<Map<String, dynamic>> ops, int paraStart) {
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
      if (m != null) {
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

  _RtfInlineState copy() {
    return _RtfInlineState()
      ..bold = bold
      ..italic = italic
      ..underline = underline
      ..strike = strike
      ..script = script
      ..font = font
      ..size = size
      ..link = link;
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
  }

  /// Quill attribute map for the current state. Keys match what the toolbar
  /// applies (Attribute.bold/italic/underline/strikeThrough/script/font/
  /// size/link).
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
