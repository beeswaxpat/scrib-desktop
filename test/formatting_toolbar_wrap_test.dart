import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrib_desktop/widgets/formatting_toolbar_widget.dart';

/// Regression tests for the v1.8.0 toolbar fix. The toolbar used to be a
/// fixed-height Row that OVERFLOWED at narrow window widths, clipping the
/// list buttons (and everything right of them) off-screen. It must now wrap,
/// keeping every control reachable at any reasonable width.
void main() {
  Widget harness(QuillController controller, double width) {
    return MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: SingleChildScrollView(
              child: ScribFormattingToolbar(controller: controller),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('renders without overflow at 700px and keeps all buttons visible',
      (tester) async {
    final controller = QuillController.basic();
    addTearDown(controller.dispose);

    await tester.pumpWidget(harness(controller, 700));
    // A RenderFlex overflow surfaces as a FlutterError in tests — the old
    // fixed Row fails here.
    expect(tester.takeException(), isNull);

    for (final icon in [
      Icons.format_list_bulleted,
      Icons.format_list_numbered,
      Icons.checklist,
      Icons.link,
      Icons.subscript,
      Icons.superscript,
      Icons.format_quote,
      Icons.format_clear,
    ]) {
      final f = find.byIcon(icon);
      expect(f, findsOneWidget, reason: '$icon missing from toolbar');
      // Every button must sit fully inside the available width — not clipped
      // past the right edge like the old Row.
      expect(tester.getRect(f).right, lessThanOrEqualTo(700),
          reason: '$icon is clipped outside the toolbar width');
    }
  });

  testWidgets('bullet button applies a bullet list to the current line',
      (tester) async {
    final controller = QuillController.basic();
    addTearDown(controller.dispose);
    controller.document.insert(0, 'first line');
    controller.updateSelection(
        const TextSelection.collapsed(offset: 3), ChangeSource.local);

    await tester.pumpWidget(harness(controller, 700));
    await tester.tap(find.byIcon(Icons.format_list_bulleted));
    await tester.pump();

    final listValue = controller
        .getSelectionStyle()
        .attributes[Attribute.list.key]
        ?.value;
    expect(listValue, 'bullet');

    // Clicking numbered while on a bullet SWITCHES (the old toggle removed).
    await tester.tap(find.byIcon(Icons.format_list_numbered));
    await tester.pump();
    expect(
        controller.getSelectionStyle().attributes[Attribute.list.key]?.value,
        'ordered');

    // Clicking numbered again removes the list.
    await tester.tap(find.byIcon(Icons.format_list_numbered));
    await tester.pump();
    expect(controller.getSelectionStyle().attributes[Attribute.list.key],
        isNull);
  });

  testWidgets('checklist button applies unchecked and toggles off from checked',
      (tester) async {
    final controller = QuillController.basic();
    addTearDown(controller.dispose);
    controller.document.insert(0, 'todo item');
    controller.updateSelection(
        const TextSelection.collapsed(offset: 2), ChangeSource.local);

    await tester.pumpWidget(harness(controller, 700));
    await tester.tap(find.byIcon(Icons.checklist));
    await tester.pump();
    expect(
        controller.getSelectionStyle().attributes[Attribute.list.key]?.value,
        'unchecked');

    // Simulate the user ticking the box, then clicking the toolbar button:
    // it must REMOVE the checklist, not flip it back to unchecked.
    controller.formatSelection(Attribute.checked);
    await tester.pump();
    await tester.tap(find.byIcon(Icons.checklist));
    await tester.pump();
    expect(controller.getSelectionStyle().attributes[Attribute.list.key],
        isNull);
  });
}
