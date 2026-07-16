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
}) {
  return showDialog<double>(
    context: context,
    builder: (ctx) => _FontSizeInputDialog(current: current, min: min, max: max),
  );
}

/// Owns its controller so the framework disposes it when the route is removed
/// (after the exit animation) — same lifecycle pattern as the password
/// dialogs. The old function-local controller was disposed the moment
/// showDialog's future completed, while the closing dialog was still animating
/// out with a TextField bound to it.
class _FontSizeInputDialog extends StatefulWidget {
  final double current;
  final double min;
  final double max;

  const _FontSizeInputDialog({
    required this.current,
    required this.min,
    required this.max,
  });

  @override
  State<_FontSizeInputDialog> createState() => _FontSizeInputDialogState();
}

class _FontSizeInputDialogState extends State<_FontSizeInputDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: '${widget.current.round()}');
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit(String value) {
    final parsed = double.tryParse(value);
    if (parsed == null) return;
    Navigator.pop(context, parsed.clamp(widget.min, widget.max));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      title: const Text('Set Text Size'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(
          labelText: 'Font size (${widget.min.toInt()}-${widget.max.toInt()})',
          border: const OutlineInputBorder(),
          enabledBorder: const OutlineInputBorder(),
          focusedBorder: const OutlineInputBorder(),
        ),
        onSubmitted: _submit,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => _submit(_controller.text),
          child: const Text('Apply'),
        ),
      ],
    );
  }
}
