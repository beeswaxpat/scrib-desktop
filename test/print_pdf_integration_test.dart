import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:scrib_desktop/services/print_service.dart';
import 'package:scrib_desktop/services/windows_print.dart';
import 'package:ffi/ffi.dart';

/// End-to-end print through the real native path: RichEdit layout, StartDoc,
/// EM_FORMATRANGE, EndDoc, into the Microsoft Print to PDF driver. The print
/// dialog is skipped (the DC comes from CreateDC) and the driver writes to
/// the file the test names instead of asking where to save.
///
/// Opt-in, because it needs a Windows machine with that printer installed:
///   set SCRIB_PRINT_TEST=1 (and optionally SCRIB_PRINT_OUT to a folder)
///   flutter test test/print_pdf_integration_test.dart
final _gdi32 = DynamicLibrary.open('gdi32.dll');
final _createDC = _gdi32.lookupFunction<
    IntPtr Function(Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>, Pointer),
    int Function(Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>, Pointer)>(
  'CreateDCW',
);
final _deleteDC =
    _gdi32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('DeleteDC');

void main() {
  final enabled =
      Platform.isWindows && Platform.environment['SCRIB_PRINT_TEST'] == '1';
  final skip = enabled ? false : 'set SCRIB_PRINT_TEST=1 on Windows to run';

  late Directory out;
  setUpAll(() {
    if (!enabled) return;
    final named = Platform.environment['SCRIB_PRINT_OUT'];
    out = named != null
        ? (Directory(named)..createSync(recursive: true))
        : Directory.systemTemp.createTempSync('scrib_print_');
  });

  int pdfDc() {
    final device = 'Microsoft Print to PDF'.toNativeUtf16();
    try {
      return _createDC(nullptr, device, nullptr, nullptr);
    } finally {
      calloc.free(device);
    }
  }

  Future<File> printToPdf(String name, PrintJob job,
      {PrintPlan plan = const PrintPlan(),
      int expectPages = -1,
      int expectPrinted = -1}) async {
    final file = File('${out.path}${Platform.pathSeparator}$name.pdf');
    if (file.existsSync()) file.deleteSync();
    final hdc = pdfDc();
    expect(hdc, isNot(0), reason: 'Microsoft Print to PDF must be installed');
    final PrintOutcome outcome;
    try {
      outcome = printRtfToDc(hdc, job.rtf,
          docName: job.title, plan: plan, debugOutputPath: file.path);
    } finally {
      _deleteDC(hdc);
    }
    expect(outcome.status, PrintStatus.printed, reason: '$outcome');
    if (expectPages >= 0) expect(outcome.pageCount, expectPages);
    if (expectPrinted >= 0) expect(outcome.pagesPrinted, expectPrinted);
    // The spooler finishes the file after EndDoc returns.
    for (var i = 0; i < 100 && (!file.existsSync() || file.lengthSync() == 0); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(file.existsSync(), isTrue);
    expect(file.readAsBytesSync().take(5), utf8.encode('%PDF-'));
    return file;
  }

  String picture() {
    final image = img.Image(width: 360, height: 180);
    for (var y = 0; y < 180; y++) {
      for (var x = 0; x < 360; x++) {
        image.setPixelRgb(x, y, x * 255 ~/ 360, 90, y * 255 ~/ 180);
      }
    }
    img.fillCircle(image,
        x: 180, y: 90, radius: 60, color: img.ColorRgb8(230, 30, 40));
    return 'data:image/png;base64,${base64Encode(img.encodePng(image))}';
  }

  test('a formatted rich note with an image prints to PDF', () async {
    final delta = jsonEncode([
      {'insert': 'Scrib print test'},
      {'insert': '\n', 'attributes': {'header': 1}},
      {'insert': 'Plain words, then '},
      {'insert': 'bold', 'attributes': {'bold': true}},
      {'insert': ', '},
      {'insert': 'italic', 'attributes': {'italic': true}},
      {'insert': ', '},
      {'insert': 'underlined', 'attributes': {'underline': true}},
      {'insert': ' and '},
      {'insert': 'red', 'attributes': {'color': '#d32f2f'}},
      {'insert': ' text with a '},
      {'insert': 'highlight', 'attributes': {'background': '#ffeb3b'}},
      {'insert': '.\nA link to '},
      {'insert': 'scrib.blog', 'attributes': {'link': 'https://scrib.blog'}},
      {'insert': ' and some '},
      {'insert': 'Consolas 18', 'attributes': {'font': 'Consolas', 'size': 18}},
      {'insert': '.\nFirst bullet'},
      {'insert': '\n', 'attributes': {'list': 'bullet'}},
      {'insert': 'Second bullet'},
      {'insert': '\n', 'attributes': {'list': 'bullet'}},
      {'insert': 'Step one'},
      {'insert': '\n', 'attributes': {'list': 'ordered'}},
      {'insert': 'Step two'},
      {'insert': '\n', 'attributes': {'list': 'ordered'}},
      {'insert': 'The picture below should be a gradient with a red circle:\n'},
      {
        'insert': {'image': picture()},
        'attributes': {'style': 'width: 240px;'}
      },
      {'insert': '\nEnd of note.\n'},
    ]);
    final job = PrintService.buildJob(
        richText: true,
        plainText: '',
        deltaJson: delta,
        fontFamily: 'Calibri',
        fontSize: 14,
        title: 'Scrib print test (rich)');
    expect(job.dropped, isFalse);
    await printToPdf('rich', job, expectPages: 1, expectPrinted: 1);
  }, skip: skip);

  test('a long plain note prints across pages, copies and ranges honored',
      () async {
    final text = [
      for (var i = 1; i <= 120; i++)
        'Line $i: plain text in the tab font, with {braces} and \\backslashes\\ and café.'
    ].join('\n');
    final job = PrintService.buildJob(
        richText: false,
        plainText: text,
        deltaJson: '',
        fontFamily: 'Consolas',
        fontSize: 12,
        title: 'Scrib print test (plain)');
    await printToPdf('plain', job);
    // Pages 2-3, two collated copies: four sheets.
    await printToPdf('plain_p2-3_x2', job,
        plan: const PrintPlan(ranges: [(2, 3)], copies: 2, collate: true),
        expectPrinted: 4);
  }, skip: skip);

  test('a range past the last page starts no job', () {
    final job = PrintService.buildJob(
        richText: false,
        plainText: 'one short line',
        deltaJson: '',
        fontFamily: 'Calibri',
        fontSize: 14,
        title: 'Scrib print test (range)');
    final hdc = pdfDc();
    try {
      final outcome = printRtfToDc(hdc, job.rtf,
          docName: job.title,
          plan: const PrintPlan(ranges: [(5, 7)]),
          debugOutputPath: '${out.path}${Platform.pathSeparator}never.pdf');
      expect(outcome.status, PrintStatus.noPagesInRange);
      expect(outcome.pageCount, 1);
    } finally {
      _deleteDC(hdc);
    }
    expect(File('${out.path}${Platform.pathSeparator}never.pdf').existsSync(),
        isFalse);
  }, skip: skip);
}
