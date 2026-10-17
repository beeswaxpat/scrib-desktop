import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:scrib_desktop/main.dart';
import 'package:scrib_desktop/providers/editor_provider.dart';
import 'package:scrib_desktop/services/file_service.dart';
import 'package:scrib_desktop/services/settings_service.dart';

/// Issue #25: quitting crashed the process (0xC000041D inside
/// flutter_windows.dll) on every close. windowManager.destroy() posts WM_QUIT,
/// so the Flutter view was torn down while the window was still focused. The
/// quit flow must close through WM_CLOSE (setPreventClose(false) + close())
/// and never call destroy().
void main() {
  const channel = MethodChannel('window_manager');
  late Directory tmp;
  late SettingsService settings;
  late EditorProvider editor;
  late FileService fs;
  late List<MethodCall> calls;

  /// When set, the mock answers close() the way the native plugin does: it
  /// sends a 'close' event back before the window goes away.
  late bool echoCloseEvent;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('scrib_quit_');
    settings = SettingsService();
    await settings.initForTests(tmp.path);
    fs = FileService();
    editor = EditorProvider(fs, settings);
    calls = [];
    echoCloseEvent = false;
  });

  tearDown(() async {
    await Hive.close();
    try { await tmp.delete(recursive: true); } catch (_) {}
  });

  Future<void> pumpApp(WidgetTester t) async {
    final messenger = t.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'close' && echoCloseEvent) {
        Future<void>.delayed(
            Duration.zero,
            () => messenger.handlePlatformMessage(
                  channel.name,
                  const StandardMethodCodec().encodeMethodCall(const MethodCall(
                      'onEvent', {'eventName': 'close'})),
                  (_) {},
                ));
      }
      return null;
    });
    messenger.setMockMethodCallHandler(
        const MethodChannel('desktop_drop'), (_) async => null);
    addTearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      messenger.setMockMethodCallHandler(
          const MethodChannel('desktop_drop'), null);
    });
    await t.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(ScribDesktopApp(
      settingsService: settings,
      editorProvider: editor,
      fileService: fs,
    ));
    await t.pump(const Duration(milliseconds: 50));
  }

  /// The plain-mode toolbar's fixed 130 px font dropdown overflows in the
  /// test font (every glyph is a full em square). That is a harness artifact,
  /// unrelated to quitting, so it is dropped; every other error still fails
  /// the test. Call the returned function at the end of the test body.
  VoidCallback ignoreTestFontOverflow() {
    final original = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exceptionAsString().contains('RenderFlex overflowed')) return;
      original?.call(details);
    };
    return () => FlutterError.onError = original;
  }

  /// What the native side sends when the user clicks the title-bar X.
  Future<void> clickClose(WidgetTester t) async {
    await t.binding.defaultBinaryMessenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
          const MethodCall('onEvent', {'eventName': 'close'})),
      (_) {},
    );
    await t.pump();
  }

  /// The quit flow does real Hive I/O (session save), so let it run on the
  /// real event loop until the window is asked to close.
  Future<void> waitForClose(WidgetTester t) => t.runAsync(() async {
        for (var i = 0; i < 100 && !calls.any((c) => c.method == 'close'); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });

  List<String> quitCalls() => [
        for (final c in calls)
          if (c.method == 'destroy' ||
              c.method == 'close' ||
              (c.method == 'setPreventClose' &&
                  c.arguments['isPreventClose'] == false))
            c.method == 'setPreventClose' ? 'allowClose' : c.method,
      ];

  testWidgets('quitting with nothing unsaved closes the window, never destroy()',
      (t) async {
    final restore = ignoreTestFontOverflow();
    await pumpApp(t);
    await t.runAsync(() => clickClose(t));
    await waitForClose(t);
    await t.pump(const Duration(milliseconds: 100));

    expect(quitCalls(), ['allowClose', 'close']);
    expect(t.takeException(), isNull);
    restore();
  });

  testWidgets('Discard & Quit on an unsaved rich-text note closes cleanly',
      (t) async {
    editor.toggleEditorMode();
    editor.updateDeltaJson('[{"insert":"unsaved rich text\\n"}]');
    await pumpApp(t);

    await t.runAsync(() => clickClose(t));
    await t.pumpAndSettle();
    expect(find.text('Unsaved Changes'), findsOneWidget);
    expect(quitCalls(), isEmpty, reason: 'nothing closes until the user picks');

    await t.tap(find.text('Discard & Quit'));
    await t.pump();
    await waitForClose(t);
    await t.pump(const Duration(milliseconds: 300));

    expect(quitCalls(), ['allowClose', 'close']);
    expect(t.takeException(), isNull);
  });

  testWidgets('the WM_CLOSE sent by close() does not re-enter the quit flow',
      (t) async {
    echoCloseEvent = true;
    editor.toggleEditorMode();
    editor.updateDeltaJson('[{"insert":"unsaved\\n"}]');
    await pumpApp(t);

    await t.runAsync(() => clickClose(t));
    await t.pumpAndSettle();
    await t.tap(find.text('Discard & Quit'));
    await t.pump();
    await waitForClose(t);
    await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await t.pumpAndSettle();

    expect(quitCalls(), ['allowClose', 'close']);
    expect(find.text('Unsaved Changes'), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('Cancel keeps the app open', (t) async {
    final restore = ignoreTestFontOverflow();
    editor.activeTab!.controller.text = 'typed';
    await pumpApp(t);

    await t.runAsync(() => clickClose(t));
    await t.pumpAndSettle();
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();

    expect(quitCalls(), isEmpty);
    expect(editor.activeTab!.controller.text, 'typed');
    restore();
  });
}
