import 'dart:convert';

/// Converts between Quill Delta JSON and RTF format.
///
/// Supports: bold, italic, underline, strikethrough, font family, font size,
/// headers, bullet lists, numbered lists, and block quotes.
class RtfService {
  /// Convert Quill Delta JSON string to RTF string
  String deltaToRtf(String deltaJson) {
    if (deltaJson.isEmpty) return _wrapRtf('');

    final ops = jsonDecode(deltaJson) as List<dynamic>;
    final fonts = <String>{'Times New Roman'}; // Default font at index 0

    // First pass: collect all fonts used
    for (final op in ops) {
      if (op is Map && op.containsKey('attributes')) {
        final attrs = op['attributes'] as Map<String, dynamic>?;
        if (attrs != null && attrs.containsKey('font')) {
          fonts.add(attrs['font'] as String);
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
  String rtfToDelta(String rtfContent) {
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

  void _parseRtfContent(String content, List<Map<String, dynamic>> ops, Map<int, String> fonts) {
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
              underline = true;
              break;
            case 'ulnone':
              flushText();
              underline = false;
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
            // Hex character
            if (i + 3 < content.length) {
              final hex = content.substring(i + 2, i + 4);
              final code = int.tryParse(hex, radix: 16);
              if (code != null) {
                textBuffer.write(String.fromCharCode(code));
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

  String _inlineFormatting(Map<String, dynamic> attrs, List<String> fontList) {
    if (attrs.isEmpty) return '';

    final buf = StringBuffer('{');
    if (attrs.containsKey('bold') && attrs['bold'] == true) buf.write('\\b');
    if (attrs.containsKey('italic') && attrs['italic'] == true) buf.write('\\i');
    if (attrs.containsKey('underline') && attrs['underline'] == true) buf.write('\\ul');
    if (attrs.containsKey('strike') && attrs['strike'] == true) buf.write('\\strike');
    if (attrs.containsKey('font')) {
      final fontIndex = fontList.indexOf(attrs['font'] as String);
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

  String _inlineFormattingClose(Map<String, dynamic> attrs) {
    if (attrs.isEmpty) return '';
    return '}';
  }

  String _blockFormattingOpen(Map<String, dynamic> attrs) {
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
    }
    return '';
  }

  String _blockFormattingClose(Map<String, dynamic> attrs) {
    if (attrs.containsKey('header') ||
        attrs.containsKey('blockquote') ||
        attrs.containsKey('list')) {
      return '}';
    }
    return '';
  }

  String _wrapRtf(String content, {String fontTable = '{\\fonttbl{\\f0\\fswiss Times New Roman;}}'}) {
    return '{\\rtf1\\ansi\\deff0\n'
        '$fontTable\n'
        '$content\n'
        '}';
  }

  String _escapeRtf(String text) {
    final buf = StringBuffer();
    for (final codeUnit in text.codeUnits) {
      if (codeUnit == 0x5C) { // backslash
        buf.write('\\\\');
      } else if (codeUnit == 0x7B) { // {
        buf.write('\\{');
      } else if (codeUnit == 0x7D) { // }
        buf.write('\\}');
      } else if (codeUnit > 127) {
        buf.write('\\u$codeUnit?');
      } else {
        buf.writeCharCode(codeUnit);
      }
    }
    return buf.toString();
  }
}
