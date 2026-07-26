import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Prompt for an existing .scrb password (open flow).
/// Returns null on cancel, non-empty password string on submit.
Future<String?> showPasswordPrompt(
  BuildContext context, {
  required String title,
  required String message,
}) {
  return showDialog<String>(
    context: context,
    builder: (ctx) => _PasswordPromptDialog(title: title, message: message),
  );
}

/// Prompt to set a new password for encrypting a file.
/// Requires 8+ characters and two matching entries.
/// Returns null on cancel, password string on submit.
Future<String?> showSetPasswordDialog(BuildContext context) {
  return showDialog<String>(
    context: context,
    builder: (ctx) => const _SetPasswordDialog(),
  );
}

/// Owns its controller/focus node so they are disposed by the framework when
/// the route is removed (after the exit animation) — not while the dialog is
/// still animating out, and without leaking a node per rebuild.
class _PasswordPromptDialog extends StatefulWidget {
  final String title;
  final String message;
  const _PasswordPromptDialog({required this.title, required this.message});

  @override
  State<_PasswordPromptDialog> createState() => _PasswordPromptDialogState();
}

class _PasswordPromptDialogState extends State<_PasswordPromptDialog> {
  final _controller = TextEditingController();
  final _keyboardFocus = FocusNode();
  bool _obscure = true;

  @override
  void dispose() {
    _controller.dispose();
    _keyboardFocus.dispose();
    super.dispose();
  }

  void _submit() {
    if (_controller.text.isNotEmpty) {
      Navigator.pop(context, _controller.text);
    }
  }

  @override
  Widget build(BuildContext context) {
    final capsLock = HardwareKeyboard.instance.lockModesEnabled
        .contains(KeyboardLockMode.capsLock);
    return KeyboardListener(
      focusNode: _keyboardFocus,
      onKeyEvent: (_) => setState(() {}),
      child: AlertDialog(
        title: Text(widget.title),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(widget.message),
              const SizedBox(height: 16),
              Semantics(
                label: 'Password',
                textField: true,
                child: TextField(
                  controller: _controller,
                  obscureText: _obscure,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: 'Password',
                    border: const OutlineInputBorder(),
                    enabledBorder: const OutlineInputBorder(),
                    focusedBorder: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscure ? Icons.visibility_off : Icons.visibility,
                        size: 20,
                      ),
                      onPressed: () => setState(() => _obscure = !_obscure),
                      tooltip: _obscure ? 'Show password' : 'Hide password',
                    ),
                  ),
                  onSubmitted: (_) => _submit(),
                ),
              ),
              if (capsLock) const _CapsLockWarning(),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: _submit,
            child: const Text('Open'),
          ),
        ],
      ),
    );
  }
}

class _SetPasswordDialog extends StatefulWidget {
  const _SetPasswordDialog();

  @override
  State<_SetPasswordDialog> createState() => _SetPasswordDialogState();
}

class _SetPasswordDialogState extends State<_SetPasswordDialog> {
  final _controller1 = TextEditingController();
  final _controller2 = TextEditingController();
  final _keyboardFocus = FocusNode();
  String? _error;
  bool _obscure1 = true;
  bool _obscure2 = true;

  @override
  void dispose() {
    _controller1.dispose();
    _controller2.dispose();
    _keyboardFocus.dispose();
    super.dispose();
  }

  void _submit() {
    if (_controller1.text.isEmpty) {
      setState(() => _error = 'Password cannot be empty');
      return;
    }
    if (_controller1.text.length < 8) {
      setState(() => _error = 'Password must be at least 8 characters');
      return;
    }
    if (_controller1.text != _controller2.text) {
      setState(() => _error = 'Passwords do not match');
      return;
    }
    Navigator.pop(context, _controller1.text);
  }

  @override
  Widget build(BuildContext context) {
    final capsLock = HardwareKeyboard.instance.lockModesEnabled
        .contains(KeyboardLockMode.capsLock);
    return KeyboardListener(
      focusNode: _keyboardFocus,
      onKeyEvent: (_) => setState(() {}),
      child: AlertDialog(
        title: const Text('Set Encryption Password'),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('This password will be required to open the file.'),
              const SizedBox(height: 8),
              const _NoRecoveryWarning(),
              const SizedBox(height: 16),
              Semantics(
                label: 'Password',
                textField: true,
                child: TextField(
                  controller: _controller1,
                  obscureText: _obscure1,
                  autofocus: true,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: 'Password',
                    border: const OutlineInputBorder(),
                    enabledBorder: const OutlineInputBorder(),
                    focusedBorder: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscure1 ? Icons.visibility_off : Icons.visibility,
                        size: 20,
                      ),
                      onPressed: () => setState(() => _obscure1 = !_obscure1),
                      tooltip: _obscure1 ? 'Show password' : 'Hide password',
                    ),
                  ),
                ),
              ),
              _PasswordStrengthBar(password: _controller1.text),
              const SizedBox(height: 8),
              Semantics(
                label: 'Confirm password',
                textField: true,
                child: TextField(
                  controller: _controller2,
                  obscureText: _obscure2,
                  decoration: InputDecoration(
                    labelText: 'Confirm Password',
                    border: const OutlineInputBorder(),
                    enabledBorder: const OutlineInputBorder(),
                    focusedBorder: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscure2 ? Icons.visibility_off : Icons.visibility,
                        size: 20,
                      ),
                      onPressed: () => setState(() => _obscure2 = !_obscure2),
                      tooltip: _obscure2 ? 'Show password' : 'Hide password',
                    ),
                  ),
                  onSubmitted: (_) => _submit(),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'A long passphrase of several words is stronger than a short '
                'complex one.',
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              if (capsLock) const _CapsLockWarning(),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 12,
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: _submit,
            child: const Text('Encrypt'),
          ),
        ],
      ),
    );
  }
}

/// Prominent reminder that encryption is offline and there is no recovery.
class _NoRecoveryWarning extends StatelessWidget {
  const _NoRecoveryWarning();

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.error;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.gpp_maybe_outlined, size: 16, color: color),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            'There is no password recovery. If you forget this password, the '
            'file cannot be opened.',
            style: TextStyle(fontSize: 12, color: color),
          ),
        ),
      ],
    );
  }
}

/// How strong the offline estimator judges a password to be, weakest first.
enum PasswordStrength { veryWeak, weak, fair, good, strong }

/// Base words and passwords that sit at the top of every public breach corpus,
/// plus the ones people reach for when a prompt demands a "strong" password.
///
/// The old meter scored on length and character-class count alone, so
/// "Password123!", "qwertyuiop123456" and sixteen letter a's all lit up green
/// "Strong" while a rockyou+rules run finds every one of them in minutes. A
/// password that reduces to a member of this set (after case folding, leet
/// unmapping, and stripping a digit or punctuation suffix) is disqualified on
/// its own, whatever its length or character variety.
const Set<String> _commonWords = {
  '123456', '1234567', '12345678', '123456789', '1234567890', '111111',
  '000000', '654321', '121212', '112233', '123123', '696969', '11111111',
  'password', 'passwd', 'pass', 'password1', 'passw0rd', 'letmein', 'welcome',
  'admin', 'administrator', 'root', 'user', 'guest', 'test', 'testing',
  'login', 'default', 'changeme', 'secret', 'private', 'access', 'master',
  'qwerty', 'qwertyui', 'qwertyuiop', 'qwerty123', 'asdf', 'asdfgh',
  'asdfghjk', 'asdfghjkl', 'zxcvbn', 'zxcvbnm', 'qazwsx', 'qwe123', '1qaz2wsx',
  'abc', 'abc123', 'abcd', 'abcdef', 'abcdefg', 'aaaaaa', 'iloveyou',
  'trustno', 'trustnoi', 'sunshine', 'princess', 'dragon', 'monkey', 'shadow',
  'michael', 'jennifer', 'jordan', 'jessica', 'daniel', 'thomas', 'robert',
  'ashley', 'nicole', 'hunter', 'harley', 'ranger', 'buster', 'tigger',
  'charlie', 'george', 'andrew', 'joshua', 'matthew', 'anthony', 'william',
  'football', 'baseball', 'basketball', 'soccer', 'hockey', 'superman',
  'batman', 'starwars', 'pokemon', 'minecraft', 'computer', 'internet',
  'whatever', 'freedom', 'killer', 'ginger', 'summer', 'winter', 'spring',
  'autumn', 'january', 'february', 'march', 'april', 'june', 'july', 'august',
  'september', 'october', 'november', 'december', 'monday', 'friday',
  'flower', 'chocolate', 'cookie', 'butterfly', 'purple', 'orange', 'silver',
  'diamond', 'phoenix', 'thunder', 'money', 'love', 'lovely', 'angel',
  'baby', 'sweety', 'sweetie', 'family', 'forever', 'hello', 'helloworld',
  'nothing', 'nopassword', 'letmein1', 'iloveu', 'scrib', 'notes', 'note',
  'journal', 'diary', 'encrypted', 'encryption', 'keepout', 'myself',
};

/// Substitutions people actually make, so 'P@ssw0rd' collapses onto the
/// dictionary word it is rather than reading as four character classes.
const Map<String, String> _leetMap = {
  '4': 'a', '@': 'a', '8': 'b', '(': 'c', '3': 'e', '6': 'g', '1': 'i',
  '!': 'i', '|': 'l', '0': 'o', '5': 's', r'$': 's', '7': 't', '+': 't',
  '2': 'z',
};

/// Rows a cracker's sequence rules walk. Runs along any of these cost about
/// as much as a single character no matter how long they get.
const List<String> _sequenceRows = [
  'abcdefghijklmnopqrstuvwxyz',
  '0123456789',
  'qwertyuiop',
  'asdfghjkl',
  'zxcvbnm',
  r'!@#$%^&*()',
];

/// Roughly how many distinct keys a sequence can start on, which is all a
/// sequence costs to guess beyond its direction and length.
const double _sequenceStartCount = 47;

double _log2(double v) => math.log(v) / math.ln2;

String _canonical(String s) {
  final sb = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    final ch = s[i];
    sb.write(_leetMap[ch] ?? ch);
  }
  return sb.toString();
}

/// Whether the whole password is one known word wearing a disguise: a leet
/// spelling, a leading capital, a digit run on the end, a bang on the end.
bool _reducesToCommonWord(String password) {
  final lower = password.toLowerCase();
  final core = lower.replaceAll(RegExp(r'^[^a-z0-9]+|[^a-z0-9]+$'), '');
  final stem = core.replaceAll(RegExp(r'^[0-9]+|[0-9]+$'), '');
  for (final candidate in {lower, core, stem}) {
    if (candidate.isEmpty) continue;
    if (_commonWords.contains(candidate)) return true;
    if (_commonWords.contains(_canonical(candidate))) return true;
  }
  return false;
}

/// Longest block-repeat starting at [start], as (total length, block length):
/// 'aaaaaaaa' is one 'a' plus a count, and 'abababab' is one 'ab' plus a
/// count, not eight independent characters. Blocks longer than eight are not
/// searched, which keeps the walk linear enough for a pasted input.
(int, int) _blockRepeatAt(String s, int start) {
  var bestTotal = 0;
  var bestBlock = 0;
  final maxBlock = math.min(8, (s.length - start) ~/ 2);
  for (var block = 1; block <= maxBlock; block++) {
    final unit = s.substring(start, start + block);
    var reps = 1;
    while (start + (reps + 1) * block <= s.length &&
        s.substring(start + reps * block, start + (reps + 1) * block) == unit) {
      reps++;
    }
    if (reps >= 2 && reps * block > bestTotal) {
      bestTotal = reps * block;
      bestBlock = block;
    }
  }
  return (bestTotal, bestBlock);
}

/// Length of the longest keyboard walk or counting run starting at [start],
/// in either direction ('qwerty', '123456', 'abcd', '9876').
int _sequenceRunLength(String s, int start) {
  var best = 1;
  for (final row in _sequenceRows) {
    final from = row.indexOf(s[start]);
    if (from < 0) continue;
    for (final step in const [1, -1]) {
      var idx = from;
      var n = 1;
      while (start + n < s.length) {
        final next = idx + step;
        if (next < 0 || next >= row.length || row[next] != s[start + n]) break;
        idx = next;
        n++;
      }
      if (n > best) best = n;
    }
  }
  return best;
}

/// Whether a plausible year starts at [start]. Birth years and this year are a
/// couple of hundred guesses, not four independent digits.
bool _isYearAt(String s, int start) {
  if (start + 4 > s.length) return false;
  final chunk = s.substring(start, start + 4);
  for (var i = 0; i < 4; i++) {
    final code = chunk.codeUnitAt(i);
    if (code < 0x30 || code > 0x39) return false;
  }
  final year = int.parse(chunk);
  return year >= 1900 && year <= 2099;
}

/// Only this many leading characters are pattern-analyzed; anything past it is
/// charged at the flat per-character rate. Nobody types a four-kilobyte
/// password, but somebody can paste one, and the meter reruns on every
/// keystroke, so the pattern walk needs a ceiling.
const int _maxAnalyzedLength = 256;

/// Rough guess-count estimate in bits: the alphabet a cracker would have to
/// walk, minus everything that a rule set generates for free.
double _estimateBits(String pw) {
  final folded = pw.toLowerCase();
  final lower = folded.length <= _maxAnalyzedLength
      ? folded
      : folded.substring(0, _maxAnalyzedLength);
  final hasLower = RegExp(r'[a-z]').hasMatch(pw);
  final hasUpper = RegExp(r'[A-Z]').hasMatch(pw);
  final hasDigit = RegExp(r'[0-9]').hasMatch(pw);
  final hasSymbol = RegExp(r'[^A-Za-z0-9]').hasMatch(pw);
  // Capitalising only the first letter is what nearly everyone does, so it is
  // worth one bit, not a whole extra character class. This is the single
  // biggest reason the old meter over-scored: 'Password123!' claimed all four
  // classes when the capital and the trailing '!' are both free to a cracker.
  final onlyLeadingUpper =
      hasUpper && !RegExp(r'[A-Z]').hasMatch(pw.substring(1));

  var alphabet = 0;
  if (hasLower) alphabet += 26;
  if (hasUpper && !onlyLeadingUpper) alphabet += 26;
  if (hasDigit) alphabet += 10;
  if (hasSymbol) alphabet += 33;
  if (alphabet == 0) alphabet = 26; // All caps, by the rule above.
  final perChar = _log2(alphabet.toDouble());

  var bits = onlyLeadingUpper ? 1.0 : 0.0;
  var i = 0;
  // Walk the folded form, not the original: toLowerCase can change a string's
  // length on some scripts, and indexing pw by lower's positions would throw.
  while (i < lower.length) {
    final (repeatTotal, repeatBlock) = _blockRepeatAt(lower, i);
    final sequence = _sequenceRunLength(lower, i);
    if (repeatTotal >= 4 && repeatTotal >= sequence) {
      bits += repeatBlock * perChar + _log2(repeatTotal / repeatBlock);
      i += repeatTotal;
    } else if (sequence >= 3) {
      bits += _log2(_sequenceStartCount) + 1 + _log2(sequence.toDouble());
      i += sequence;
    } else if (_isYearAt(lower, i)) {
      bits += 8;
      i += 4;
    } else {
      bits += perChar;
      i++;
    }
  }
  // Anything past the analyzed prefix is charged flat.
  return bits + (folded.length - lower.length) * perChar;
}

/// Classifies password strength purely client-side, offline, with no packages
/// and nothing sent anywhere. The estimate is guess-count based rather than
/// length based, because length and character variety are exactly what a
/// cracker's rule set already covers: common words, keyboard walks, counting
/// runs, repeated characters and years are charged what they cost to guess.
PasswordStrength estimatePasswordStrength(String password) {
  if (password.isEmpty) return PasswordStrength.veryWeak;
  if (_reducesToCommonWord(password)) return PasswordStrength.veryWeak;

  final bits = _estimateBits(password);
  if (bits < 30) return PasswordStrength.veryWeak;
  if (bits < 45) return PasswordStrength.weak;
  if (bits < 60) return PasswordStrength.fair;
  if (bits < 75) return PasswordStrength.good;
  return PasswordStrength.strong;
}

({double fraction, String label, Color color}) _passwordStrength(
    String pw, ColorScheme scheme) {
  if (pw.isEmpty) return (fraction: 0.0, label: '', color: scheme.outline);
  return switch (estimatePasswordStrength(pw)) {
    PasswordStrength.veryWeak =>
      (fraction: 0.2, label: 'Very weak', color: scheme.error),
    PasswordStrength.weak =>
      (fraction: 0.4, label: 'Weak', color: const Color(0xFFF97316)),
    PasswordStrength.fair =>
      (fraction: 0.6, label: 'Fair', color: const Color(0xFFF59E0B)),
    PasswordStrength.good =>
      (fraction: 0.8, label: 'Good', color: const Color(0xFF10B981)),
    PasswordStrength.strong =>
      (fraction: 1.0, label: 'Strong', color: const Color(0xFF22C55E)),
  };
}

class _PasswordStrengthBar extends StatelessWidget {
  final String password;
  const _PasswordStrengthBar({required this.password});

  @override
  Widget build(BuildContext context) {
    if (password.isEmpty) return const SizedBox(height: 12);
    final scheme = Theme.of(context).colorScheme;
    final s = _passwordStrength(password, scheme);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: s.fraction,
                minHeight: 4,
                backgroundColor: scheme.surfaceContainerHighest,
                valueColor: AlwaysStoppedAnimation<Color>(s.color),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            s.label,
            style: TextStyle(fontSize: 11, color: s.color),
          ),
        ],
      ),
    );
  }
}

class _CapsLockWarning extends StatelessWidget {
  const _CapsLockWarning();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Icon(
            Icons.warning_amber_rounded,
            size: 14,
            color: Theme.of(context).colorScheme.error,
          ),
          const SizedBox(width: 6),
          Text(
            'Caps Lock is on',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.error,
            ),
          ),
        ],
      ),
    );
  }
}
