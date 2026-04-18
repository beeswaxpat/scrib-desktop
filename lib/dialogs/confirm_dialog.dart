import 'package:flutter/material.dart';

enum UnsavedChangesChoice { save, discard, cancel }

/// Standard "you have unsaved changes" confirmation.
/// Returns [UnsavedChangesChoice.cancel] on close / outside-tap.
Future<UnsavedChangesChoice> showUnsavedChangesDialog(
  BuildContext context, {
  required String fileName,
}) async {
  final result = await showDialog<UnsavedChangesChoice>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Save Changes?'),
      content: Text('$fileName has unsaved changes.'),
      actions: [
        TextButton(
          onPressed: () =>
              Navigator.pop(ctx, UnsavedChangesChoice.discard),
          child: const Text('Discard'),
        ),
        TextButton(
          onPressed: () =>
              Navigator.pop(ctx, UnsavedChangesChoice.cancel),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.pop(ctx, UnsavedChangesChoice.save),
          child: const Text('Save'),
        ),
      ],
    ),
  );
  return result ?? UnsavedChangesChoice.cancel;
}

/// Generic two-button confirmation.
Future<bool> showScribConfirm(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Confirm',
  String cancelLabel = 'Cancel',
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(cancelLabel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// Dialog to enter a custom font size. Returns clamped double or null on cancel.
Future<double?> showFontSizeInput(
  BuildContext context, {
  required double current,
  double min = 6,
  double max = 144,
}) async {
  final controller = TextEditingController(text: '${current.round()}');

  double? parse(String v) {
    final parsed = double.tryParse(v);
    if (parsed == null) return null;
    return parsed.clamp(min, max);
  }

  final result = await showDialog<double>(
    context: context,
    builder: (ctx) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      title: const Text('Set Text Size'),
      content: TextField(
        controller: controller,
        autofocus: true,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(
          labelText: 'Font size (${min.toInt()}–${max.toInt()})',
          border: const OutlineInputBorder(),
          enabledBorder: const OutlineInputBorder(),
          focusedBorder: const OutlineInputBorder(),
        ),
        onSubmitted: (value) {
          final parsed = parse(value);
          if (parsed != null) Navigator.pop(ctx, parsed);
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final parsed = parse(controller.text);
            if (parsed != null) Navigator.pop(ctx, parsed);
          },
          child: const Text('Apply'),
        ),
      ],
    ),
  );
  controller.dispose();
  return result;
}
