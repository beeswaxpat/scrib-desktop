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

/// Classifies password strength purely client-side (length-weighted, with a
/// character-class bonus). No content is sent anywhere.
({double fraction, String label, Color color}) _passwordStrength(
    String pw, ColorScheme scheme) {
  if (pw.isEmpty) return (fraction: 0, label: '', color: scheme.outline);

  final classes = [
    RegExp(r'[a-z]'),
    RegExp(r'[A-Z]'),
    RegExp(r'[0-9]'),
    RegExp(r'[^a-zA-Z0-9]'),
  ].where((re) => re.hasMatch(pw)).length;

  int score; // 0..3
  if (pw.length < 8) {
    score = 0;
  } else if (pw.length >= 16 || (pw.length >= 12 && classes >= 3)) {
    score = 3;
  } else if (pw.length >= 12 || classes >= 3) {
    score = 2;
  } else {
    score = 1;
  }

  switch (score) {
    case 0:
      return (fraction: 0.25, label: 'Weak', color: scheme.error);
    case 1:
      return (fraction: 0.5, label: 'Fair', color: const Color(0xFFF59E0B));
    case 2:
      return (fraction: 0.75, label: 'Good', color: const Color(0xFF10B981));
    default:
      return (fraction: 1.0, label: 'Strong', color: const Color(0xFF22C55E));
  }
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
