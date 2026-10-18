import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:win32/win32.dart';

/// Printing through Windows' own RichEdit control (msftedit.dll, the engine
/// WordPad prints with), driven over dart:ffi.
///
/// The note arrives as RTF in memory. It is streamed into a hidden,
/// message-only RichEdit window and the standard print dialog picks the
/// printer, pages and copies. RichEdit then draws each page onto the printer's
/// device context with EM_FORMATRANGE between StartDoc and EndDoc. Nothing here
/// writes a file: the only place the note goes is the printer the user chose.
///
/// Everything in [printRtfWithDialog] is synchronous on purpose. Windows
/// windows, device contexts and COM apartments belong to the thread that made
/// them, and a Dart isolate stays on one thread only while it runs without
/// awaiting. [PrintService] runs it in its own isolate so the dialog and the
/// rendering never block the Flutter UI thread.

/// How a print request ended.
enum PrintStatus {
  /// The job reached the print queue.
  printed,

  /// The user closed the print dialog or the printer's own save prompt.
  cancelled,

  /// The pages the user asked for do not exist (for example pages 5-7 of a
  /// three-page note), so no job was started.
  noPagesInRange,

  /// The note laid out to no pages at all.
  empty,

  /// Something failed. [PrintOutcome.detail] says what, for the debug log.
  failed,
}

/// The result of [printRtfWithDialog]. Plain data, so it crosses isolates.
class PrintOutcome {
  final PrintStatus status;

  /// Pages in the note as laid out for the chosen printer.
  final int pageCount;

  /// Pages sent, counting every copy.
  final int pagesPrinted;

  /// The printer the user picked, when the dialog reported it.
  final String? printer;

  /// What failed, for the debug log only. Never shown verbatim to the user.
  final String? detail;

  const PrintOutcome(
    this.status, {
    this.pageCount = 0,
    this.pagesPrinted = 0,
    this.printer,
    this.detail,
  });

  @override
  String toString() =>
      'PrintOutcome($status, pages: $pageCount, printed: $pagesPrinted, '
      'printer: $printer, detail: $detail)';
}

/// The pages and copies to print. Page numbers are 1-based and inclusive.
class PrintPlan {
  /// Null prints every page.
  final List<(int, int)>? ranges;
  final int copies;

  /// True prints copy 1 in full, then copy 2; false prints each page
  /// [copies] times in a row.
  final bool collate;

  const PrintPlan({this.ranges, this.copies = 1, this.collate = true});

  /// The 0-based page indexes to print, in order, for a note of [pageCount]
  /// pages. Ranges past the end are clipped and reversed ranges are read as
  /// written. A page named twice prints twice, as in other Windows apps.
  List<int> pageOrder(int pageCount) {
    final pages = <int>[];
    final source = ranges;
    if (source == null) {
      for (var i = 0; i < pageCount; i++) {
        pages.add(i);
      }
    } else {
      for (final (from, to) in source) {
        final lo = from < to ? from : to;
        final hi = from < to ? to : from;
        for (var p = lo; p <= hi && p <= pageCount; p++) {
          if (p >= 1) pages.add(p - 1);
        }
      }
    }
    if (pages.isEmpty) return pages;
    final n = copies < 1 ? 1 : copies;
    if (n == 1) return pages;
    if (collate) {
      return [for (var c = 0; c < n; c++) ...pages];
    }
    return [
      for (final p in pages)
        for (var c = 0; c < n; c++) p
    ];
  }
}

// ── Native types ──────────────────────────────────────────────────────────
//
// Layouts follow the Windows SDK headers for x64. commdlg.h uses natural
// alignment on 64-bit; richedit.h wraps its structs in pshpack4.h, which
// moves EDITSTREAM.pfnCallback to offset 12 (size 20, not 24). A wrong
// layout here is a native crash that takes unsaved notes with it, so
// [debugStructSizes] pins every size in a test.

final class _PrintPageRange extends Struct {
  @Uint32()
  external int nFromPage;
  @Uint32()
  external int nToPage;
}

final class _PrintDlgEx extends Struct {
  @Uint32()
  external int lStructSize;
  @IntPtr()
  external int hwndOwner;
  external Pointer hDevMode;
  external Pointer hDevNames;
  @IntPtr()
  external int hDC;
  @Uint32()
  external int flags;
  @Uint32()
  external int flags2;
  @Uint32()
  external int exclusionFlags;
  @Uint32()
  external int nPageRanges;
  @Uint32()
  external int nMaxPageRanges;
  external Pointer<_PrintPageRange> lpPageRanges;
  @Uint32()
  external int nMinPage;
  @Uint32()
  external int nMaxPage;
  @Uint32()
  external int nCopies;
  @IntPtr()
  external int hInstance;
  external Pointer<Utf16> lpPrintTemplateName;
  external Pointer lpCallback;
  @Uint32()
  external int nPropertyPages;
  external Pointer lphPropertyPages;
  @Uint32()
  external int nStartPage;
  @Uint32()
  external int dwResultAction;
}

final class _DevNames extends Struct {
  @Uint16()
  external int wDriverOffset;
  @Uint16()
  external int wDeviceOffset;
  @Uint16()
  external int wOutputOffset;
  @Uint16()
  external int wDefault;
}

final class _DocInfo extends Struct {
  @Int32()
  external int cbSize;
  external Pointer<Utf16> lpszDocName;
  external Pointer<Utf16> lpszOutput;
  external Pointer<Utf16> lpszDatatype;
  @Uint32()
  external int fwType;
}

@Packed(4)
final class _CharRange extends Struct {
  @Int32()
  external int cpMin;
  @Int32()
  external int cpMax;
}

@Packed(4)
final class _FormatRange extends Struct {
  @IntPtr()
  external int hdc;
  @IntPtr()
  external int hdcTarget;
  external RECT rc;
  external RECT rcPage;
  external _CharRange chrg;
}

typedef _EditStreamCallbackNative = Uint32 Function(
    IntPtr cookie, Pointer<Uint8> buffer, Int32 cb, Pointer<Int32> pcb);

@Packed(4)
final class _EditStream extends Struct {
  @IntPtr()
  external int dwCookie;
  @Uint32()
  external int dwError;
  external Pointer<NativeFunction<_EditStreamCallbackNative>> pfnCallback;
}

/// Native struct sizes, for the layout regression test.
@visibleForTesting
Map<String, int> debugStructSizes() => {
      'PRINTDLGEXW': sizeOf<_PrintDlgEx>(),
      'PRINTPAGERANGE': sizeOf<_PrintPageRange>(),
      'DEVNAMES': sizeOf<_DevNames>(),
      'DOCINFOW': sizeOf<_DocInfo>(),
      'CHARRANGE': sizeOf<_CharRange>(),
      'FORMATRANGE': sizeOf<_FormatRange>(),
      'EDITSTREAM': sizeOf<_EditStream>(),
    };

// ── Constants (commdlg.h, richedit.h, winerror.h) ─────────────────────────

const int _pdNoSelection = 0x00000004;
const int _pdPageNums = 0x00000002;
const int _pdCollate = 0x00000010;
const int _pdReturnDc = 0x00000100;
const int _pdNoCurrentPage = 0x00800000;
const int _startPageGeneral = 0xFFFFFFFF;
const int _pdResultPrint = 1;

const int _emExGetSel = WM_USER + 52;
const int _emExLimitText = WM_USER + 53;
const int _emExSetSel = WM_USER + 55;
const int _emFormatRange = WM_USER + 57;
const int _emStreamIn = WM_USER + 73;
const int _sfRtf = 0x0002;

const int _errorCancelled = 1223;
const int _rpcEChangedMode = 0x80010106;

/// Page ranges the dialog can hand back.
const int _maxPageRanges = 32;

/// Highest page number the dialog accepts. The real count is only known once
/// the note is laid out for the printer the user picks.
const int _maxPageNumber = 0xFFFF;

/// Margin on every side, in twips (1440 per inch).
const int _marginTwips = 1440;

/// A printer whose page is narrower or shorter than this (in twips) after
/// margins, such as a receipt or label printer, prints edge to edge within
/// its printable area instead.
const int _minTextAreaTwips = 1440;

/// Layout gives up past this many pages instead of looping without end.
const int _maxPages = 100000;

final _comdlg32 = DynamicLibrary.open('comdlg32.dll');
final _gdi32 = DynamicLibrary.open('gdi32.dll');

final _printDlgEx = _comdlg32.lookupFunction<
    Int32 Function(Pointer<_PrintDlgEx>),
    int Function(Pointer<_PrintDlgEx>)>('PrintDlgExW');
final _startDoc = _gdi32.lookupFunction<Int32 Function(IntPtr, Pointer<_DocInfo>),
    int Function(int, Pointer<_DocInfo>)>('StartDocW');
final _endDoc =
    _gdi32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('EndDoc');
final _abortDoc = _gdi32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>('AbortDoc');
final _startPage = _gdi32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>('StartPage');
final _endPage =
    _gdi32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('EndPage');

// ── EM_STREAMIN source ────────────────────────────────────────────────────
//
// RichEdit pulls the RTF through this callback during the EM_STREAMIN call,
// on the same thread, so plain isolate-local state is enough.

Uint8List? _streamSource;
int _streamOffset = 0;

int _streamInCallback(
    int cookie, Pointer<Uint8> buffer, int cb, Pointer<Int32> pcb) {
  final source = _streamSource;
  if (source == null || cb < 0) {
    pcb.value = 0;
    return 1; // non-zero stops the stream
  }
  final remaining = source.length - _streamOffset;
  final n = remaining < cb ? remaining : cb;
  if (n > 0) {
    buffer.asTypedList(n).setRange(0, n, source, _streamOffset);
    _streamOffset += n;
  }
  pcb.value = n;
  return 0;
}

// ── The print flow ────────────────────────────────────────────────────────

/// Shows the standard Windows print dialog over Scrib's window and prints
/// [rtf] to the printer the user picks, as the job [docName].
///
/// Synchronous; run it in its own isolate (see [PrintService]).
PrintOutcome printRtfWithDialog(String rtf, String docName) {
  final owner = _findAppWindow();
  if (owner == 0) {
    return const PrintOutcome(PrintStatus.failed,
        detail: 'Scrib window not found');
  }

  // The dialog's printer list is shell UI and needs a single-threaded
  // apartment on this thread (OleInitialize makes one).
  final ole = _OleScope.enter();
  if (ole == null) {
    return const PrintOutcome(PrintStatus.failed, detail: 'OleInitialize');
  }

  final pd = calloc<_PrintDlgEx>();
  final ranges = calloc<_PrintPageRange>(_maxPageRanges);
  var hdc = 0;
  try {
    pd.ref
      ..lStructSize = sizeOf<_PrintDlgEx>()
      ..hwndOwner = owner
      ..flags = _pdReturnDc | _pdNoSelection | _pdNoCurrentPage
      ..nMinPage = 1
      ..nMaxPage = _maxPageNumber
      ..nMaxPageRanges = _maxPageRanges
      ..lpPageRanges = ranges
      ..nCopies = 1
      ..nStartPage = _startPageGeneral;

    final hr = _printDlgEx(pd);
    hdc = pd.ref.hDC;
    final printer = _printerName(pd.ref.hDevNames);
    _freeGlobal(pd.ref.hDevMode);
    _freeGlobal(pd.ref.hDevNames);

    if (hr != S_OK) {
      return PrintOutcome(PrintStatus.failed,
          detail: 'PrintDlgEx 0x${(hr & 0xFFFFFFFF).toRadixString(16)}');
    }
    if (pd.ref.dwResultAction != _pdResultPrint) {
      return const PrintOutcome(PrintStatus.cancelled);
    }
    if (hdc == 0) {
      return PrintOutcome(PrintStatus.failed,
          printer: printer, detail: 'no printer DC');
    }

    final flags = pd.ref.flags;
    List<(int, int)>? picked;
    if (flags & _pdPageNums != 0) {
      final n = pd.ref.nPageRanges.clamp(0, _maxPageRanges);
      picked = [
        for (var i = 0; i < n; i++)
          ((ranges + i).ref.nFromPage, (ranges + i).ref.nToPage)
      ];
    }
    // Without PD_USEDEVMODECOPIESANDCOLLATE the dialog leaves copies and
    // collation to the application, which works the same on every printer,
    // including drivers that cannot make copies themselves.
    final plan = PrintPlan(
      ranges: picked,
      copies: pd.ref.nCopies < 1 ? 1 : pd.ref.nCopies,
      collate: flags & _pdCollate != 0,
    );

    final outcome = printRtfToDc(hdc, rtf, docName: docName, plan: plan);
    return PrintOutcome(outcome.status,
        pageCount: outcome.pageCount,
        pagesPrinted: outcome.pagesPrinted,
        printer: printer,
        detail: outcome.detail);
  } finally {
    if (hdc != 0) DeleteDC(hdc);
    calloc.free(ranges);
    calloc.free(pd);
    ole.exit();
  }
}

/// One OleInitialize on this thread, paired with its OleUninitialize.
///
/// A single-threaded apartment for the print dialog's shell UI and for the
/// imaging RichEdit decodes pictures with. S_FALSE (already initialized here)
/// still needs the matching uninitialize; RPC_E_CHANGED_MODE means another
/// apartment owns the thread and must be left alone.
class _OleScope {
  final bool _owned;

  const _OleScope._(this._owned);

  static _OleScope? enter() {
    final hr = OleInitialize(nullptr);
    if (hr >= 0) return const _OleScope._(true);
    if ((hr & 0xFFFFFFFF) == _rpcEChangedMode) return const _OleScope._(false);
    return null;
  }

  void exit() {
    if (_owned) OleUninitialize();
  }
}

/// Lays [rtf] out for the printer behind [hdc] and prints the pages [plan]
/// asks for as one job named [docName]. The caller owns [hdc].
///
/// [debugOutputPath] is a test seam: it names the file a driver such as
/// Microsoft Print to PDF writes, so an integration test can print without
/// the driver's save prompt. The app never sets it.
PrintOutcome printRtfToDc(
  int hdc,
  String rtf, {
  required String docName,
  PrintPlan plan = const PrintPlan(),
  @visibleForTesting String? debugOutputPath,
}) {
  final ole = _OleScope.enter();
  if (ole == null) {
    return const PrintOutcome(PrintStatus.failed, detail: 'OleInitialize');
  }
  final doc = _RichEditDocument.load(rtf);
  if (doc == null) {
    ole.exit();
    return const PrintOutcome(PrintStatus.failed,
        detail: 'RichEdit could not load the note');
  }
  final arena = Arena();
  try {
    final layout = _PageLayout.of(hdc);
    if (layout == null) {
      return const PrintOutcome(PrintStatus.failed,
          detail: 'printer reported no page size');
    }
    final fr = arena<_FormatRange>();
    fr.ref
      ..hdc = hdc
      ..hdcTarget = hdc;
    layout.applyTo(fr.ref);

    final starts = doc.paginate(fr);
    if (starts.isEmpty) {
      return const PrintOutcome(PrintStatus.empty);
    }
    final order = plan.pageOrder(starts.length);
    if (order.isEmpty) {
      return PrintOutcome(PrintStatus.noPagesInRange,
          pageCount: starts.length);
    }

    final info = arena<_DocInfo>();
    info.ref
      ..cbSize = sizeOf<_DocInfo>()
      ..lpszDocName = docName.toNativeUtf16(allocator: arena)
      ..lpszOutput = debugOutputPath == null
          ? nullptr
          : debugOutputPath.toNativeUtf16(allocator: arena);

    final job = _startDoc(hdc, info);
    if (job <= 0) {
      final error = GetLastError();
      if (error == _errorCancelled) {
        return PrintOutcome(PrintStatus.cancelled, pageCount: starts.length);
      }
      return PrintOutcome(PrintStatus.failed,
          pageCount: starts.length, detail: 'StartDoc error $error');
    }

    var printed = 0;
    for (final page in order) {
      if (_startPage(hdc) <= 0) {
        _abortDoc(hdc);
        return PrintOutcome(PrintStatus.failed,
            pageCount: starts.length,
            pagesPrinted: printed,
            detail: 'StartPage error ${GetLastError()}');
      }
      fr.ref.chrg
        ..cpMin = starts[page]
        ..cpMax = page + 1 < starts.length ? starts[page + 1] : -1;
      doc.formatRange(fr, render: true);
      if (_endPage(hdc) <= 0) {
        _abortDoc(hdc);
        return PrintOutcome(PrintStatus.failed,
            pageCount: starts.length,
            pagesPrinted: printed,
            detail: 'EndPage error ${GetLastError()}');
      }
      printed++;
    }
    if (_endDoc(hdc) <= 0) {
      return PrintOutcome(PrintStatus.failed,
          pageCount: starts.length,
          pagesPrinted: printed,
          detail: 'EndDoc error ${GetLastError()}');
    }
    return PrintOutcome(PrintStatus.printed,
        pageCount: starts.length, pagesPrinted: printed);
  } finally {
    doc.dispose();
    arena.releaseAll();
    ole.exit();
  }
}

/// Scrib's own top-level window, the print dialog's owner. Matching on the
/// process as well as the class keeps another Flutter app's window out.
int _findAppWindow() {
  final className = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
  final pid = calloc<Uint32>();
  try {
    final me = GetCurrentProcessId();
    var hwnd = 0;
    for (var guard = 0; guard < 1000; guard++) {
      hwnd = FindWindowEx(0, hwnd, className, nullptr);
      if (hwnd == 0) return 0;
      GetWindowThreadProcessId(hwnd, pid);
      if (pid.value == me) return hwnd;
    }
    return 0;
  } finally {
    calloc.free(pid);
    calloc.free(className);
  }
}

String? _printerName(Pointer hDevNames) {
  if (hDevNames.address == 0) return null;
  final locked = GlobalLock(hDevNames);
  if (locked.address == 0) return null;
  try {
    // DEVNAMES offsets count characters from the start of the block.
    final offset = locked.cast<_DevNames>().ref.wDeviceOffset;
    final name = (locked.cast<Uint16>() + offset).cast<Utf16>().toDartString();
    return name.isEmpty ? null : name;
  } finally {
    GlobalUnlock(hDevNames);
  }
}

void _freeGlobal(Pointer handle) {
  if (handle.address != 0) GlobalFree(handle);
}

/// Page geometry in twips, in the printer DC's coordinates, whose origin is
/// the corner of the printable area rather than the corner of the paper.
class _PageLayout {
  final int pageLeft, pageTop, pageRight, pageBottom;
  final int left, top, right, bottom;

  const _PageLayout(this.pageLeft, this.pageTop, this.pageRight,
      this.pageBottom, this.left, this.top, this.right, this.bottom);

  static _PageLayout? of(int hdc) {
    final dpiX = GetDeviceCaps(hdc, LOGPIXELSX);
    final dpiY = GetDeviceCaps(hdc, LOGPIXELSY);
    if (dpiX <= 0 || dpiY <= 0) return null;
    int tx(int px) => px * 1440 ~/ dpiX;
    int ty(int px) => px * 1440 ~/ dpiY;

    final printableW = tx(GetDeviceCaps(hdc, HORZRES));
    final printableH = ty(GetDeviceCaps(hdc, VERTRES));
    if (printableW <= 0 || printableH <= 0) return null;
    var physW = tx(GetDeviceCaps(hdc, PHYSICALWIDTH));
    var physH = ty(GetDeviceCaps(hdc, PHYSICALHEIGHT));
    final offX = tx(GetDeviceCaps(hdc, PHYSICALOFFSETX));
    final offY = ty(GetDeviceCaps(hdc, PHYSICALOFFSETY));
    // Display-like devices report no physical page; use the printable area.
    if (physW <= 0) physW = printableW;
    if (physH <= 0) physH = printableH;

    // One inch from the paper's edge, kept inside what the printer can reach.
    var left = _marginTwips - offX;
    var top = _marginTwips - offY;
    var right = physW - _marginTwips - offX;
    var bottom = physH - _marginTwips - offY;
    if (left < 0) left = 0;
    if (top < 0) top = 0;
    if (right > printableW) right = printableW;
    if (bottom > printableH) bottom = printableH;
    if (right - left < _minTextAreaTwips) {
      left = 0;
      right = printableW;
    }
    if (bottom - top < _minTextAreaTwips) {
      top = 0;
      bottom = printableH;
    }
    return _PageLayout(-offX, -offY, physW - offX, physH - offY, left, top,
        right, bottom);
  }

  void applyTo(_FormatRange fr) {
    fr.rc
      ..left = left
      ..top = top
      ..right = right
      ..bottom = bottom;
    fr.rcPage
      ..left = pageLeft
      ..top = pageTop
      ..right = pageRight
      ..bottom = pageBottom;
  }
}

/// A hidden RichEdit control holding one note.
class _RichEditDocument {
  final int hwnd;

  _RichEditDocument._(this.hwnd);

  /// Streams [rtf] into a new message-only RichEdit window, or returns null
  /// if the control cannot be created or will not take the text.
  static _RichEditDocument? load(String rtf) {
    final dll = 'Msftedit.dll'.toNativeUtf16();
    final cls = 'RICHEDIT50W'.toNativeUtf16();
    final empty = ''.toNativeUtf16();
    try {
      // Loaded for the life of the process, like WordPad does. The class is
      // registered process-wide and stays valid for later prints.
      if (LoadLibrary(dll) == 0) return null;
      // HWND_MESSAGE: a window that never shows and receives no broadcasts.
      // This thread does not pump messages while it renders, and a hidden
      // top-level window here would stall any program that broadcasts a
      // settings change until the print finished.
      //
      // Not ES_READONLY: a read-only RichEdit refuses to insert the images
      // in the RTF it is given, and the note prints without its pictures.
      // A message-only window takes no keyboard or mouse input anyway.
      final hwnd = CreateWindowEx(0, cls, empty, ES_MULTILINE, 0, 0, 0, 0,
          HWND_MESSAGE, 0, GetModuleHandle(nullptr), nullptr);
      if (hwnd == 0) return null;
      final doc = _RichEditDocument._(hwnd);
      if (!doc._streamIn(rtf)) {
        doc.dispose();
        return null;
      }
      return doc;
    } finally {
      calloc.free(dll);
      calloc.free(cls);
      calloc.free(empty);
    }
  }

  bool _streamIn(String rtf) {
    // Without this RichEdit stops reading at 32K characters of text.
    SendMessage(hwnd, _emExLimitText, 0, 0x7FFFFFFE);
    final bytes = Uint8List.fromList(utf8.encode(rtf));
    final es = calloc<_EditStream>();
    try {
      es.ref
        ..dwCookie = 0
        ..dwError = 0
        ..pfnCallback = Pointer.fromFunction<_EditStreamCallbackNative>(
            _streamInCallback, 1);
      _streamSource = bytes;
      _streamOffset = 0;
      SendMessage(hwnd, _emStreamIn, _sfRtf, es.address);
      return es.ref.dwError == 0;
    } finally {
      _streamSource = null;
      _streamOffset = 0;
      // The note may be one the user keeps encrypted; do not leave this copy
      // lying in freed memory longer than the GC would anyway.
      bytes.fillRange(0, bytes.length, 0);
      calloc.free(es);
    }
  }

  /// Character position where each page starts, laid out for [fr]'s device.
  List<int> paginate(Pointer<_FormatRange> fr) {
    final all = calloc<_CharRange>();
    try {
      all.ref
        ..cpMin = 0
        ..cpMax = -1;
      SendMessage(hwnd, _emExSetSel, 0, all.address);
      SendMessage(hwnd, _emExGetSel, 0, all.address);
      final end = all.ref.cpMax;
      final starts = <int>[];
      var cp = 0;
      while (cp < end && starts.length < _maxPages) {
        starts.add(cp);
        fr.ref.chrg
          ..cpMin = cp
          ..cpMax = -1;
        final next = formatRange(fr, render: false);
        if (next <= cp) break; // no progress: stop rather than loop forever
        cp = next;
      }
      _releaseFormatCache();
      return starts;
    } finally {
      calloc.free(all);
    }
  }

  /// EM_FORMATRANGE: lays out (and with [render], draws) one page starting
  /// at fr.chrg.cpMin and returns where the next page starts.
  int formatRange(Pointer<_FormatRange> fr, {required bool render}) =>
      SendMessage(hwnd, _emFormatRange, render ? 1 : 0, fr.address);

  void _releaseFormatCache() => SendMessage(hwnd, _emFormatRange, 0, 0);

  void dispose() {
    _releaseFormatCache();
    DestroyWindow(hwnd);
  }
}
