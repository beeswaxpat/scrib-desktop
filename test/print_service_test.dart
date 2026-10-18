import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scrib_desktop/providers/editor_provider.dart';
import 'package:scrib_desktop/screens/main_screen.dart' show printGateFor;
import 'package:scrib_desktop/services/print_service.dart';
import 'package:scrib_desktop/services/rtf_service.dart';
import 'package:scrib_desktop/services/windows_print.dart';

/// File > Print: the gate that decides whether a tab may print, the RTF the
/// printer receives, the page plan and the native struct layouts.
void main() {
  String plainOf(String rtf) => [
        for (final op in jsonDecode(RtfService.rtfToDelta(rtf)) as List)
          if (op['insert'] is String) op['insert'] as String,
      ].join();

  group('plainTextToRtf', () {
    String rtf(String text, {String font = 'Consolas', double size = 12}) =>
        RtfService.plainTextToRtf(text, fontFamily: font, fontSize: size);

    test('is one RTF document in the tab font and size', () {
      final out = rtf('hello');
      expect(out, startsWith('{\\rtf1\\ansi\\ansicpg1252\\deff0\n'));
      expect(out, contains('{\\fonttbl{\\f0\\fnil Consolas;}}'));
      expect(out, contains('\\fs24 hello\\par'));
      expect(out, endsWith('}'));
    });

    test('every line is its own paragraph, whatever the line ending', () {
      final out = rtf('one\r\ntwo\rthree\nfour');
      expect('\\par'.allMatches(out).length, 4);
      expect(plainOf(out), 'one\ntwo\nthree\nfour\n');
    });

    test('RTF syntax in the note prints as characters', () {
      const text = r'{\rtf1 \b not bold} and \par and {braces}';
      final out = rtf(text);
      // Every backslash and brace arrives escaped, so none opens a group or
      // starts a control word.
      expect(out, contains(r'\{\\rtf1 \\b not bold\} and \\par and \{braces\}'));
      expect(plainOf(out), '$text\n');
    });

    test('non-ASCII text and emoji survive as \\u escapes', () {
      const text = 'café, naïve, 日本語 and 😀';
      final out = rtf(text);
      expect(out.codeUnits.every((c) => c < 128), isTrue,
          reason: 'the stream RichEdit reads is plain ASCII');
      expect(plainOf(out), '$text\n');
    });

    test('tabs are kept', () {
      expect(rtf('a\tb'), contains('a\\tab b'));
    });

    test('an empty note is one empty paragraph', () {
      expect(plainOf(rtf('')), '\n');
    });

    test('font size is in points, bounded like a run size', () {
      expect(rtf('x', size: 14), contains('\\fs28 x'));
      expect(rtf('x', size: 10.5), contains('\\fs21 x'));
      expect(rtf('x', size: 1000), contains('\\fs800 x'));
      expect(rtf('x', size: double.nan), contains('\\fs24 x'));
      expect(rtf('x', size: -3), contains('\\fs24 x'));
    });

    test('a font name cannot break out of the font table', () {
      final out = rtf('x', font: r'Evil;}}\b{');
      expect(out, contains(r'{\fonttbl{\f0\fnil Evil\}\}\\b\{;}}'));
      expect(rtf('x', font: '  '), contains('{\\f0\\fnil Calibri;}'));
    });
  });

  group('exportDelta base font', () {
    final delta = jsonEncode([
      {'insert': 'plain '},
      {'insert': 'calibri run', 'attributes': {'font': 'Calibri'}},
      {'insert': '\n'},
    ]);

    test('saves are unchanged: no base font means Times New Roman, no size',
        () {
      expect(RtfService.exportDelta('').rtf,
          '{\\rtf1\\ansi\\ansicpg1252\\deff0\n'
          '{\\fonttbl{\\f0\\fswiss Times New Roman;}}\n\n}');
      final out = RtfService.exportDelta(delta).rtf;
      expect(
          out,
          startsWith('{\\rtf1\\ansi\\ansicpg1252\\deff0\n'
              '{\\fonttbl{\\f0\\fswiss Times New Roman;}{\\f1\\fswiss Calibri;}}\n'
              'plain '));
      expect(RegExp(r'\\fs\d').hasMatch(out), isFalse);
      expect(RtfService.deltaToRtf(delta), out);
    });

    test('printing puts the editor default font and size first', () {
      final out = RtfService.exportDelta(delta,
              baseFont: 'Calibri', baseFontSize: 14)
          .rtf;
      // Calibri is font 0, and the explicit Calibri run reuses it.
      expect(out, contains('{\\fonttbl{\\f0\\fswiss Calibri;}}'));
      expect(out, contains('\\fs28 plain '));
      expect(out, contains('{\\f0 calibri run}'));
    });

    test('a Delta that does not parse still gets the base font', () {
      final out = RtfService.exportDelta('not json',
              baseFont: 'Calibri', baseFontSize: 14)
          .rtf;
      expect(out, contains('{\\f0\\fswiss Calibri;}'));
      expect(out, contains('\\fs28 not json\\par'));
    });
  });

  group('printGateFor', () {
    const text = 'Meeting notes';
    final richText = jsonEncode([
      {'insert': '$text\n'}
    ]);

    EditorTab tab({
      String? path,
      String content = text,
      bool encrypted = false,
      bool locked = false,
      EditorMode mode = EditorMode.plainText,
      String delta = '',
    }) =>
        EditorTab(
          filePath: path,
          fileName: 'note',
          content: content,
          isEncrypted: encrypted,
          isLocked: locked,
          mode: mode,
          deltaJson: delta,
        );

    test('a plain unencrypted note is ready', () {
      expect(printGateFor(tab(path: r'C:\notes\a.txt')), PrintGate.ready);
      expect(printGateFor(tab()), PrintGate.ready);
    });

    test('a locked tab never prints, whatever else is true', () {
      expect(printGateFor(tab(path: r'C:\n\a.scrb', encrypted: true, locked: true)),
          PrintGate.locked);
      expect(printGateFor(tab(path: r'C:\n\a.scrb', content: '', locked: true)),
          PrintGate.locked);
    });

    test('an encrypted .scrb tab asks first', () {
      expect(printGateFor(tab(path: r'C:\n\a.scrb', encrypted: true)),
          PrintGate.confirmEncrypted);
    });

    test('the Ctrl+E flag alone asks, before the .scrb exists', () {
      expect(printGateFor(tab(path: r'C:\n\a.txt', encrypted: true)),
          PrintGate.confirmEncrypted);
      expect(printGateFor(tab(encrypted: true)), PrintGate.confirmEncrypted);
    });

    test('a .scrb file asks even after Ctrl+E turned the flag off', () {
      expect(printGateFor(tab(path: r'C:\n\A.SCRB', encrypted: false)),
          PrintGate.confirmEncrypted);
    });

    test('encrypted rich text asks too', () {
      expect(
          printGateFor(tab(
              path: r'C:\n\a.scrb',
              encrypted: true,
              mode: EditorMode.richText,
              delta: richText)),
          PrintGate.confirmEncrypted);
    });

    test('blank notes are refused before anything is asked', () {
      expect(printGateFor(tab(content: '')), PrintGate.empty);
      expect(printGateFor(tab(content: ' \n\t\n')), PrintGate.empty);
      expect(printGateFor(tab(path: r'C:\n\a.scrb', encrypted: true, content: '')),
          PrintGate.empty);
      expect(printGateFor(tab(mode: EditorMode.richText, delta: '')),
          PrintGate.empty);
      expect(
          printGateFor(tab(
              mode: EditorMode.richText,
              delta: jsonEncode([
                {'insert': '\n'},
                {'insert': '  \n', 'attributes': {'list': 'bullet'}},
              ]))),
          PrintGate.empty);
    });

    test('rich mode reads the Delta, not the plain-text controller', () {
      expect(printGateFor(tab(mode: EditorMode.richText, delta: richText)),
          PrintGate.ready);
      expect(
          printGateFor(tab(content: '', mode: EditorMode.richText, delta: richText)),
          PrintGate.ready);
    });

    test('a note with only an image or a table is not blank', () {
      for (final embed in [
        {'image': 'data:image/png;base64,AAAA'},
        {'scrib-table': '{}'},
      ]) {
        expect(
            printGateFor(tab(
                mode: EditorMode.richText,
                delta: jsonEncode([
                  {'insert': embed},
                  {'insert': '\n'},
                ]))),
            PrintGate.ready);
      }
    });

    test('a Delta that does not parse is printed, not called blank', () {
      expect(printGateFor(tab(mode: EditorMode.richText, delta: '{broken')),
          PrintGate.ready);
    });
  });

  group('buildJob', () {
    final png = img.encodePng(
        img.Image(width: 8, height: 4)..clear(img.ColorRgb8(10, 20, 30)));

    test('rich text keeps formatting and images, in the editor font', () {
      final job = PrintService.buildJob(
        richText: true,
        plainText: 'ignored',
        deltaJson: jsonEncode([
          {'insert': 'Bold', 'attributes': {'bold': true}},
          {'insert': '\n'},
          {'insert': {'image': 'data:image/png;base64,${base64Encode(png)}'}},
          {'insert': '\n'},
        ]),
        fontFamily: 'Consolas',
        fontSize: 20,
        title: 'Rich.rtf',
      );
      expect(job.dropped, isFalse);
      expect(job.title, 'Rich.rtf');
      expect(job.rtf, contains('{\\f0\\fswiss Calibri;}'));
      expect(job.rtf, contains('\\fs28 '));
      expect(job.rtf, contains('{\\b Bold}'));
      expect(job.rtf, contains('\\pngblip'));
      expect(job.rtf, isNot(contains('Consolas')),
          reason: 'the plain-text tab font does not apply to rich text');
    });

    test('a table or an SVG is reported as left out', () {
      for (final embed in [
        {'scrib-table': '{"rows":1,"cols":1,"cells":[["x"]]}'},
        {'image': 'data:image/svg+xml;base64,PHN2Zz48L3N2Zz4='},
      ]) {
        final job = PrintService.buildJob(
          richText: true,
          plainText: '',
          deltaJson: jsonEncode([
            {'insert': 'Before\n'},
            {'insert': embed},
            {'insert': '\nAfter\n'},
          ]),
          fontFamily: 'Calibri',
          fontSize: 14,
          title: 't',
        );
        expect(job.dropped, isTrue, reason: '$embed');
        expect(plainOf(job.rtf), contains('After'));
      }
    });

    test('plain text uses the tab font and size, never the Delta', () {
      final job = PrintService.buildJob(
        richText: false,
        plainText: 'line one\nline two',
        deltaJson: jsonEncode([
          {'insert': 'stale delta\n'}
        ]),
        fontFamily: 'Consolas',
        fontSize: 11,
        title: 'a.txt',
      );
      expect(job.dropped, isFalse);
      expect(job.rtf, contains('{\\f0\\fnil Consolas;}'));
      expect(job.rtf, contains('\\fs22 '));
      expect(plainOf(job.rtf), 'line one\nline two\n');
    });

    test('prepare gives the same job from a background isolate', () async {
      final direct = PrintService.buildJob(
          richText: false,
          plainText: 'x',
          deltaJson: '',
          fontFamily: 'Calibri',
          fontSize: 14,
          title: 't');
      final viaIsolate = await PrintService.prepare(
          richText: false,
          plainText: 'x',
          deltaJson: '',
          fontFamily: 'Calibri',
          fontSize: 14,
          title: 't');
      expect(viaIsolate.rtf, direct.rtf);
      expect(viaIsolate.dropped, direct.dropped);
    });
  });

  group('PrintPlan.pageOrder', () {
    test('no ranges prints every page once', () {
      expect(const PrintPlan().pageOrder(3), [0, 1, 2]);
      expect(const PrintPlan().pageOrder(0), isEmpty);
    });

    test('ranges are 1-based, inclusive and clipped to the note', () {
      expect(const PrintPlan(ranges: [(2, 3)]).pageOrder(5), [1, 2]);
      expect(const PrintPlan(ranges: [(1, 1), (4, 9)]).pageOrder(5), [0, 3, 4]);
      expect(const PrintPlan(ranges: [(0, 2)]).pageOrder(5), [0, 1]);
      expect(const PrintPlan(ranges: [(3, 2)]).pageOrder(5), [1, 2]);
    });

    test('a range past the last page prints nothing', () {
      expect(const PrintPlan(ranges: [(5, 7)]).pageOrder(3), isEmpty);
      expect(const PrintPlan(ranges: [(5, 7)], copies: 3).pageOrder(3), isEmpty);
    });

    test('collated copies repeat the set; uncollated repeat each page', () {
      expect(const PrintPlan(copies: 2, collate: true).pageOrder(3),
          [0, 1, 2, 0, 1, 2]);
      expect(const PrintPlan(copies: 2, collate: false).pageOrder(3),
          [0, 0, 1, 1, 2, 2]);
      expect(const PrintPlan(copies: 0).pageOrder(2), [0, 1]);
    });
  });

  group('dialog-side helpers', () {
    final skip = Platform.isWindows ? false : 'Windows API';

    test('the owner-window lookup finds no window in a test process', () {
      // flutter_tester has no FLUTTER_RUNNER_WIN32_WINDOW of its own, and a
      // window of that class in another process (another Flutter app) must
      // not be picked.
      expect(debugFindAppWindow(), 0);
    }, skip: skip);

    test('the printer name is read from a DEVNAMES block, then freed', () {
      final kernel32 = DynamicLibrary.open('kernel32.dll');
      final globalAlloc = kernel32.lookupFunction<Pointer Function(Uint32, IntPtr),
          Pointer Function(int, int)>('GlobalAlloc');
      final globalLock = kernel32.lookupFunction<Pointer Function(Pointer),
          Pointer Function(Pointer)>('GlobalLock');
      final globalUnlock = kernel32.lookupFunction<Int32 Function(Pointer),
          int Function(Pointer)>('GlobalUnlock');

      // DEVNAMES: four WORD offsets (in characters from the block start),
      // then driver, device and output names, each NUL-terminated.
      const driver = 'winspool', device = 'Microsoft Print to PDF', port = 'PORTPROMPT:';
      final chars = <int>[
        4, 4 + driver.length + 1, 4 + driver.length + 1 + device.length + 1, 0,
        ...driver.codeUnits, 0, ...device.codeUnits, 0, ...port.codeUnits, 0,
      ];
      const gmemMoveable = 0x0002;
      final block = globalAlloc(gmemMoveable, chars.length * 2);
      expect(block.address, isNot(0));
      final p = globalLock(block).cast<Uint16>();
      p.asTypedList(chars.length).setAll(0, chars);
      globalUnlock(block);

      expect(debugPrinterNameAndFree(block), device);
      expect(debugPrinterNameAndFree(nullptr), isNull);
    }, skip: skip);
  });

  test('native struct layouts match the x64 Windows SDK headers', () {
    // commdlg.h is naturally aligned on x64; richedit.h is packed to 4, which
    // is what makes EDITSTREAM 20 bytes rather than 24.
    expect(debugStructSizes(), {
      'PRINTDLGEXW': 136,
      'PRINTPAGERANGE': 8,
      'DEVNAMES': 8,
      'DOCINFOW': 40,
      'CHARRANGE': 8,
      'FORMATRANGE': 56,
      'EDITSTREAM': 20,
    });
  }, skip: sizeOf<IntPtr>() == 8 ? false : 'layouts are for 64-bit Windows');
}
