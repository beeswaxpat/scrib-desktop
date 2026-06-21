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
            children: [
              const Text('This password will be required to open the file.'),
              const SizedBox(height: 16),
              Semantics(
                label: 'Password',
                textField: true,
                child: TextField(
                  controller: _controller1,
                  obscureText: _obscure1,
                  autofocus: true,
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
