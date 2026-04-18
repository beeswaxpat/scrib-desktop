import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Prompt for an existing .scrb password (open flow).
/// Returns null on cancel, non-empty password string on submit.
Future<String?> showPasswordPrompt(
  BuildContext context, {
  required String title,
  required String message,
}) async {
  final controller = TextEditingController();
  bool obscure = true;

  final result = await showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDialogState) {
        final capsLock = HardwareKeyboard.instance.lockModesEnabled
            .contains(KeyboardLockMode.capsLock);
        return KeyboardListener(
          focusNode: FocusNode(),
          onKeyEvent: (_) => setDialogState(() {}),
          child: AlertDialog(
            title: Text(title),
            content: SizedBox(
              width: 360,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(message),
                  const SizedBox(height: 16),
                  Semantics(
                    label: 'Password',
                    textField: true,
                    child: TextField(
                      controller: controller,
                      obscureText: obscure,
                      autofocus: true,
                      decoration: InputDecoration(
                        labelText: 'Password',
                        border: const OutlineInputBorder(),
                        enabledBorder: const OutlineInputBorder(),
                        focusedBorder: const OutlineInputBorder(),
                        suffixIcon: IconButton(
                          icon: Icon(
                            obscure ? Icons.visibility_off : Icons.visibility,
                            size: 20,
                          ),
                          onPressed: () =>
                              setDialogState(() => obscure = !obscure),
                          tooltip: obscure ? 'Show password' : 'Hide password',
                        ),
                      ),
                      onSubmitted: (value) {
                        if (value.isNotEmpty) Navigator.pop(ctx, value);
                      },
                    ),
                  ),
                  if (capsLock) _CapsLockWarning(),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  if (controller.text.isNotEmpty) {
                    Navigator.pop(ctx, controller.text);
                  }
                },
                child: const Text('Open'),
              ),
            ],
          ),
        );
      },
    ),
  );
  controller.dispose();
  return result;
}

/// Prompt to set a new password for encrypting a file.
/// Requires 8+ characters and two matching entries.
/// Returns null on cancel, password string on submit.
Future<String?> showSetPasswordDialog(BuildContext context) async {
  final controller1 = TextEditingController();
  final controller2 = TextEditingController();
  String? error;
  bool obscure1 = true;
  bool obscure2 = true;

  final result = await showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDialogState) {
        final capsLock = HardwareKeyboard.instance.lockModesEnabled
            .contains(KeyboardLockMode.capsLock);

        void submit() {
          if (controller1.text.isEmpty) {
            setDialogState(() => error = 'Password cannot be empty');
            return;
          }
          if (controller1.text.length < 8) {
            setDialogState(() => error = 'Password must be at least 8 characters');
            return;
          }
          if (controller1.text != controller2.text) {
            setDialogState(() => error = 'Passwords do not match');
            return;
          }
          Navigator.pop(ctx, controller1.text);
        }

        return KeyboardListener(
          focusNode: FocusNode(),
          onKeyEvent: (_) => setDialogState(() {}),
          child: AlertDialog(
            title: const Text('Set Encryption Password'),
            content: SizedBox(
              width: 360,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'This password will be required to open the file.',
                  ),
                  const SizedBox(height: 16),
                  Semantics(
                    label: 'Password',
                    textField: true,
                    child: TextField(
                      controller: controller1,
                      obscureText: obscure1,
                      autofocus: true,
                      decoration: InputDecoration(
                        labelText: 'Password',
                        border: const OutlineInputBorder(),
                        enabledBorder: const OutlineInputBorder(),
                        focusedBorder: const OutlineInputBorder(),
                        suffixIcon: IconButton(
                          icon: Icon(
                            obscure1 ? Icons.visibility_off : Icons.visibility,
                            size: 20,
                          ),
                          onPressed: () =>
                              setDialogState(() => obscure1 = !obscure1),
                          tooltip: obscure1 ? 'Show password' : 'Hide password',
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Semantics(
                    label: 'Confirm password',
                    textField: true,
                    child: TextField(
                      controller: controller2,
                      obscureText: obscure2,
                      decoration: InputDecoration(
                        labelText: 'Confirm Password',
                        border: const OutlineInputBorder(),
                        enabledBorder: const OutlineInputBorder(),
                        focusedBorder: const OutlineInputBorder(),
                        suffixIcon: IconButton(
                          icon: Icon(
                            obscure2 ? Icons.visibility_off : Icons.visibility,
                            size: 20,
                          ),
                          onPressed: () =>
                              setDialogState(() => obscure2 = !obscure2),
                          tooltip: obscure2 ? 'Show password' : 'Hide password',
                        ),
                      ),
                      onSubmitted: (_) => submit(),
                    ),
                  ),
                  if (capsLock) _CapsLockWarning(),
                  if (error != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      error!,
                      style: TextStyle(
                        color: Theme.of(ctx).colorScheme.error,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: submit,
                child: const Text('Encrypt'),
              ),
            ],
          ),
        );
      },
    ),
  );
  controller1.dispose();
  controller2.dispose();
  return result;
}

class _CapsLockWarning extends StatelessWidget {
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
