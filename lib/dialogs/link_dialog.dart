import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import '../services/format_utils.dart';

/// Insert / edit / remove a hyperlink on the given controller's selection.
/// Word-style behavior: the cursor only needs to be INSIDE a link to edit it;
/// the edit applies to the whole contiguous link run.
Future<void> showLinkEditor(BuildContext context, QuillController controller) async {
  var selection = controller.selection;
  if (!selection.isValid) return;

  // If the cursor sits inside an existing link, expand to the full link run
  // so editing or removing affects the whole link, not a zero-width point.
  final existingUrl =
      controller.getSelectionStyle().attributes[Attribute.link.key]?.value as String?;
  if (existingUrl != null) {
    final range = _linkRangeAt(controller, selection.start, existingUrl);
    if (range != null) {
      selection = TextSelection(baseOffset: range.$1, extentOffset: range.$2);
      controller.updateSelection(selection, ChangeSource.local);
    }
  }

  final selectedText = selection.isCollapsed
      ? ''
      : controller.document.getPlainText(
          selection.start, selection.end - selection.start);

  final result = await showDialog<_LinkResult>(
    context: context,
    builder: (ctx) => _LinkDialog(
      initialText: selectedText,
      initialUrl: existingUrl ?? '',
      canRemove: existingUrl != null,
    ),
  );
  if (result == null) return;

  if (result.remove) {
    controller.formatSelection(Attribute.clone(Attribute.link, null));
    return;
  }

  final url = result.url;
  final text = result.text.isNotEmpty ? result.text : url;
  final start = selection.start;

  if (selection.isCollapsed || text != selectedText) {
    // Replace (or insert) the display text, then link exactly that span.
    controller.replaceText(
      start,
      selection.end - selection.start,
      text,
      TextSelection.collapsed(offset: start + text.length),
    );
    controller.formatText(start, text.length, LinkAttribute(url));
  } else {
    controller.formatSelection(LinkAttribute(url));
  }
}

/// Find the contiguous run of leaves around [offset] that share [url].
/// Returns (start, end) document offsets, or null if it cannot be resolved.
/// Link leaves are ordinary attached text nodes, so documentOffset is valid
/// here (unlike detached custom embeds).
(int, int)? _linkRangeAt(QuillController controller, int offset, String url) {
  try {
    final seg = controller.document.querySegmentLeafNode(offset);
    final leaf = seg.leaf;
    if (leaf == null) return null;
    if (leaf.style.attributes[Attribute.link.key]?.value != url) return null;

    var start = leaf.documentOffset;
    var end = leaf.documentOffset + leaf.length;

    var prev = leaf.previous;
    while (prev != null &&
        prev.style.attributes[Attribute.link.key]?.value == url) {
      start = prev.documentOffset;
      prev = prev.previous;
    }
    var next = leaf.next;
    while (next != null &&
        next.style.attributes[Attribute.link.key]?.value == url) {
      end = next.documentOffset + next.length;
      next = next.next;
    }
    return (start, end);
  } catch (_) {
    return null;
  }
}

class _LinkResult {
  final String text;
  final String url;
  final bool remove;
  const _LinkResult(this.text, this.url, {this.remove = false});
}

class _LinkDialog extends StatefulWidget {
  final String initialText;
  final String initialUrl;
  final bool canRemove;

  const _LinkDialog({
    required this.initialText,
    required this.initialUrl,
    required this.canRemove,
  });

  @override
  State<_LinkDialog> createState() => _LinkDialogState();
}

class _LinkDialogState extends State<_LinkDialog> {
  late final TextEditingController _textController;
  late final TextEditingController _urlController;
  late final FocusNode _urlFocus;
  String? _error;

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController(text: widget.initialText);
    _urlController = TextEditingController(text: widget.initialUrl);
    _urlFocus = FocusNode();
  }

  @override
  void dispose() {
    _textController.dispose();
    _urlController.dispose();
    _urlFocus.dispose();
    super.dispose();
  }

  void _submit() {
    final url = normalizeLinkUrl(_urlController.text);
    if (url == null) {
      setState(() {
        // normalizeLinkUrl now also refuses addresses that Windows and Dart's
        // Uri would resolve differently (backslashes, UNC paths, a "user@"
        // before the host), so the message names those rather than leaving the
        // user retyping a scheme that was never the problem.
        _error = 'Enter a web address (https://example.com) or an email '
            'address. Only http, https, and mailto links are allowed, with no '
            'backslashes and no "user@" before the host.';
      });
      _urlFocus.requestFocus();
      return;
    }
    Navigator.pop(context, _LinkResult(_textController.text.trim(), url));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.canRemove ? 'Edit Link' : 'Insert Link'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _textController,
              autofocus: widget.initialText.isEmpty && widget.initialUrl.isEmpty,
              decoration: const InputDecoration(
                labelText: 'Text to display',
                hintText: 'Optional. Uses the address if empty.',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _urlController,
              focusNode: _urlFocus,
              autofocus: widget.initialText.isNotEmpty || widget.initialUrl.isNotEmpty,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                labelText: 'Address',
                hintText: 'https://example.com',
                errorText: _error,
                errorMaxLines: 3,
              ),
            ),
          ],
        ),
      ),
      actions: [
        if (widget.canRemove)
          TextButton(
            onPressed: () =>
                Navigator.pop(context, const _LinkResult('', '', remove: true)),
            child: const Text('Remove Link'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(widget.canRemove ? 'Save' : 'Insert'),
        ),
      ],
    );
  }
}
