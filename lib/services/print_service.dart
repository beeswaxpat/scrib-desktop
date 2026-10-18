import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import '../constants.dart';
import 'rtf_service.dart';
import 'windows_print.dart';

export 'windows_print.dart' show PrintOutcome, PrintStatus;

/// What has to happen before a tab can print.
enum PrintGate {
  /// The tab is locked: its decrypted content is not in memory.
  locked,

  /// The note has no text and no images, so a print would be blank paper.
  empty,

  /// The note is encrypted. Printing sends it to the printer unencrypted, so
  /// the user confirms first.
  confirmEncrypted,

  /// Nothing stands in the way.
  ready,
}

/// A note converted for printing: the RTF RichEdit lays out, the job name the
/// print queue shows and whether anything in the note could not be included.
class PrintJob {
  final String rtf;
  final String title;

  /// True when the note has content RTF cannot hold (a table, an SVG image),
  /// which will be missing from the printout.
  final bool dropped;

  const PrintJob({required this.rtf, required this.title, required this.dropped});
}

/// File > Print: the decisions and conversion around [printRtfWithDialog].
///
/// Takes the tab's state as plain values so the service stays provider-free;
/// `main_screen.dart` reads them off the active tab. The note goes from
/// memory to RTF to the printer. No step writes it to disk.
class PrintService {
  PrintService._();

  /// The gate for a tab in this state, checked in order: a locked tab never
  /// prints, a blank note is not worth paper and an encrypted one asks.
  ///
  /// [encrypted] should be true when the tab is flagged for encryption OR its
  /// file on disk is a `.scrb`: either way the user treats this note as one
  /// that stays encrypted.
  static PrintGate gate({
    required bool isLocked,
    required bool encrypted,
    required bool richText,
    required String plainText,
    required String deltaJson,
  }) {
    if (isLocked) return PrintGate.locked;
    final blank = richText ? isBlankDelta(deltaJson) : plainText.trim().isEmpty;
    if (blank) return PrintGate.empty;
    if (encrypted) return PrintGate.confirmEncrypted;
    return PrintGate.ready;
  }

  /// True when a rich note holds only whitespace: no visible text and no
  /// embed of any kind. A Delta that does not parse is not called blank; the
  /// RTF export prints its raw text instead.
  static bool isBlankDelta(String deltaJson) {
    if (deltaJson.trim().isEmpty) return true;
    final Object? decoded;
    try {
      decoded = jsonDecode(deltaJson);
    } catch (_) {
      return false;
    }
    if (decoded is! List) return false;
    for (final op in decoded) {
      if (op is! Map) continue;
      final insert = op['insert'];
      if (insert is String) {
        if (insert.trim().isNotEmpty) return false;
      } else if (insert != null) {
        return false; // an image, a table or any other embed
      }
    }
    return true;
  }

  /// Converts a note for printing. Pure and synchronous; [prepare] runs it
  /// off the UI thread.
  ///
  /// Rich text goes through [RtfService.exportDelta] like every `.rtf` save,
  /// with the rich editor's default font so unstyled text prints the way it
  /// looks on screen. Plain text prints in the tab's own font and size.
  static PrintJob buildJob({
    required bool richText,
    required String plainText,
    required String deltaJson,
    required String fontFamily,
    required double fontSize,
    required String title,
  }) {
    if (richText) {
      final export = RtfService.exportDelta(deltaJson,
          baseFont: richTextDefaultFontFamily,
          baseFontSize: richTextDefaultFontSize);
      return PrintJob(rtf: export.rtf, title: title, dropped: export.dropped);
    }
    return PrintJob(
      rtf: RtfService.plainTextToRtf(plainText,
          fontFamily: fontFamily, fontSize: fontSize),
      title: title,
      dropped: false,
    );
  }

  /// [buildJob] in a background isolate: converting a note with many images
  /// takes long enough to drop frames.
  static Future<PrintJob> prepare({
    required bool richText,
    required String plainText,
    required String deltaJson,
    required String fontFamily,
    required double fontSize,
    required String title,
  }) {
    return Isolate.run(() => buildJob(
          richText: richText,
          plainText: plainText,
          deltaJson: deltaJson,
          fontFamily: fontFamily,
          fontSize: fontSize,
          title: title,
        ));
  }

  /// Shows the Windows print dialog and prints [job], all in a background
  /// isolate. The dialog is modal to Scrib's window while the Flutter UI keeps
  /// drawing.
  static Future<PrintOutcome> printJob(PrintJob job) async {
    if (!Platform.isWindows) {
      return const PrintOutcome(PrintStatus.failed,
          detail: 'printing needs Windows');
    }
    final rtf = job.rtf;
    final title = job.title;
    return Isolate.run(() => printRtfWithDialog(rtf, title));
  }
}
