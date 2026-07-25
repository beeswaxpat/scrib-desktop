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

/// Characters that must never appear INSIDE a link after trimming: every
/// whitespace character (space, tab, newline, unicode spaces), ASCII control
/// characters, and the invisible formatting characters Dart's `\s` class does
/// NOT cover (soft hyphen, zero-width spaces, bidi overrides, NEL). A real URL
/// percent-encodes all of them; raw occurrences are either a typo or an
/// attempt to smuggle a scheme past the allowlist.
final RegExp _linkForbiddenChars = RegExp(
  r'[\s\x00-\x1f\x7f\u0085\u00ad\u061c\u180e\u200b-\u200f'
  r'\u202a-\u202e\u2060-\u2064\u2066-\u206f\ufeff\ufff9-\ufffb]',
);

/// Shapes where Dart's [Uri] parser and the Windows shell disagree about the
/// destination, so neither gate may accept them at any scheme.
///
/// A backslash anywhere: Windows reads it as a path separator, so
/// `https:/\evil.com` and `\\host\share` resolve to something quite unlike
/// what Uri.parse reports, and the second is a UNC target that leaks an NTLM
/// challenge on contact. A leading `//` is a protocol-relative or UNC target
/// that prefixing `https://` onto would only mangle into `https:////host`.
bool _hasPathConfusion(String t) => t.contains(r'\') || t.startsWith('//');

/// Normalize user-entered link text into a launchable URL, or return null if
/// it cannot be made safe. Only http, https, and mailto are allowed: a note
/// must never carry a javascript:, file:, or other active-scheme link.
///
/// Whatever this returns is guaranteed to satisfy [isSafeLaunchUrl].
String? normalizeLinkUrl(String raw) {
  final t = raw.trim();
  if (t.isEmpty || t.contains(_linkForbiddenChars)) return null;
  if (_hasPathConfusion(t)) return null;

  final String candidate;
  final scheme = Uri.tryParse(t)?.scheme.toLowerCase() ?? '';
  if (scheme == 'http' || scheme == 'https' || scheme == 'mailto') {
    candidate = t;
  } else {
    // Reject any other explicit scheme (javascript:, file:, data:, ...).
    // A colon marks a scheme only when the part before it has no '.', '/', or
    // '@', so "example.com:8080/x" is still treated as a bare host+port.
    final colon = t.indexOf(':');
    if (colon > 0) {
      final beforeColon = t.substring(0, colon);
      if (!beforeColon.contains('.') &&
          !beforeColon.contains('/') &&
          !beforeColon.contains('@')) {
        return null;
      }
    }

    if (t.contains('@') && !t.contains('/')) {
      candidate = 'mailto:$t'; // Bare email.
    } else if (t.contains('.')) {
      candidate = 'https://$t'; // Bare domain/path.
    } else {
      return null;
    }
  }

  // The two gates must agree, and they did not: normalizeLinkUrl accepted
  // 'http:evil.com' and 'search.ms:foo', which isSafeLaunchUrl then refused,
  // so the dialog reported success and stored a link that rendered but could
  // never open. Ending here makes the launch gate the single source of truth.
  return isSafeLaunchUrl(candidate) ? candidate : null;
}

/// Whether a URL already stored in a note is safe to open in the browser.
/// This is the LAUNCH-TIME gate: a crafted .scrb or .rtf can carry any link
/// attribute without ever passing through the link dialog, so this check must
/// stand alone. Scheme allowlist (http/https/mailto, case-insensitive), the
/// raw whitespace/control-character rejection above, and a check that the URL
/// means the same thing to the shell as it does to [Uri].
bool isSafeLaunchUrl(String url) {
  final t = url.trim();
  if (t.isEmpty || t.contains(_linkForbiddenChars)) return false;
  if (_hasPathConfusion(t)) return false;

  final uri = Uri.tryParse(t);
  if (uri == null) return false;
  final scheme = uri.scheme.toLowerCase();

  // mailto: carries its address in the path, not an authority.
  if (scheme == 'mailto') return uri.path.isNotEmpty;
  if (scheme != 'http' && scheme != 'https') return false;

  // 'http:evil.com' parses with an allowed scheme but no authority at all, so
  // the shell opens something other than the host the link text shows.
  if (!uri.hasAuthority || uri.host.isEmpty) return false;

  // Userinfo is misdirection inside a note: 'https://scrib.cfd@evil.example'
  // reads as scrib.cfd and resolves to evil.example.
  if (uri.userInfo.isNotEmpty) return false;

  return true;
}
