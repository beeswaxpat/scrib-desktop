import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrib_desktop/services/rtf_service.dart';

/// RTF export of the list types added/exercised by the v1.8.0 toolbar work.
/// The critical property is BALANCED BRACES: _blockFormattingClose emits '}'
/// for every list line, so every list type must emit a matching '{'.
void main() {
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

  String delta(List<Map<String, dynamic>> ops) => jsonEncode(ops);

  test('bullet list exports balanced RTF with bullet marker', () {
    final rtf = RtfService.deltaToRtf(delta([
      {'insert': 'item one'},
      {'insert': '\n', 'attributes': {'list': 'bullet'}},
    ]));
    expect(braceBalance(rtf), 0);
    expect(rtf, contains(r"\'95")); // cp1252 bullet
    expect(rtf, contains('item one'));
  });

  test('checklist exports balanced RTF with [ ] and [x] markers', () {
    final rtf = RtfService.deltaToRtf(delta([
      {'insert': 'buy milk'},
      {'insert': '\n', 'attributes': {'list': 'unchecked'}},
      {'insert': 'done thing'},
      {'insert': '\n', 'attributes': {'list': 'checked'}},
    ]));
    expect(braceBalance(rtf), 0);
    expect(rtf, contains('[ ]'));
    expect(rtf, contains('[x]'));
    expect(rtf, contains('buy milk'));
    expect(rtf, contains('done thing'));
  });

  test('unknown list type still exports balanced RTF', () {
    final rtf = RtfService.deltaToRtf(delta([
      {'insert': 'mystery'},
      {'insert': '\n', 'attributes': {'list': 'someFutureType'}},
    ]));
    expect(braceBalance(rtf), 0);
    expect(rtf, contains('mystery'));
  });

  test('subscript and superscript export as \\sub and \\super', () {
    final rtf = RtfService.deltaToRtf(delta([
      {'insert': 'H'},
      {'insert': '2', 'attributes': {'script': 'sub'}},
      {'insert': 'O and x'},
      {'insert': '2', 'attributes': {'script': 'super'}},
      {'insert': '\n'},
    ]));
    expect(braceBalance(rtf), 0);
    expect(rtf, contains(r'\sub'));
    expect(rtf, contains(r'\super'));
  });
}
