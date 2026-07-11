import 'package:flutter_quill/flutter_quill.dart';

/// Pure formatting helpers shared by the rich-text toolbar and keyboard
/// shortcuts. Kept UI-free so they are unit-testable.

/// Resolve a click on a list button given the line's current list value.
/// Industry-standard behavior: clicking the active list type removes the
/// list; clicking a different type SWITCHES to it (it must not just remove).
Attribute resolveListToggle(String? currentValue, Attribute target) {
  if (currentValue == target.value) {
    return Attribute.clone(Attribute.list, null);
  }
  return target;
}

/// Normalize user-entered link text into a launchable URL, or return null if
/// it cannot be made safe. Only http, https, and mailto are allowed — a note
/// must never carry a javascript:, file:, or other active-scheme link.
String? normalizeLinkUrl(String raw) {
  final t = raw.trim();
  if (t.isEmpty || t.contains(' ')) return null;

  final uri = Uri.tryParse(t);
  final scheme = uri?.scheme.toLowerCase() ?? '';
  if (scheme == 'http' || scheme == 'https' || scheme == 'mailto') {
    return t;
  }

  // Reject any other explicit scheme (javascript:, file:, data:, ...).
  // A colon marks a scheme only when the part before it has no '.', '/', or
  // '@' — so "example.com:8080/x" is still treated as a bare host+port.
  final colon = t.indexOf(':');
  if (colon > 0) {
    final beforeColon = t.substring(0, colon);
    if (!beforeColon.contains('.') &&
        !beforeColon.contains('/') &&
        !beforeColon.contains('@')) {
      return null;
    }
  }

  // Bare email → mailto.
  if (t.contains('@') && !t.contains('/')) return 'mailto:$t';
  // Bare domain/path → https.
  if (t.contains('.')) return 'https://$t';
  return null;
}

/// Whether a URL already stored in a note is safe to open in the browser.
bool isSafeLaunchUrl(String url) {
  final scheme = Uri.tryParse(url.trim())?.scheme.toLowerCase() ?? '';
  return scheme == 'http' || scheme == 'https' || scheme == 'mailto';
}
