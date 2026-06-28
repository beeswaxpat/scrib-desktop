import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/calc_evaluator.dart';

/// Opens the built-in calculator. If [onInsert] is provided, an "Insert result"
/// action is shown that hands the formatted result back to the caller so it can
/// be dropped into the active note.
Future<void> showCalculatorDialog(
  BuildContext context, {
  void Function(String result)? onInsert,
}) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.4),
    builder: (ctx) => _CalculatorDialog(onInsert: onInsert),
  );
}

class _CalculatorDialog extends StatefulWidget {
  final void Function(String result)? onInsert;
  const _CalculatorDialog({this.onInsert});

  @override
  State<_CalculatorDialog> createState() => _CalculatorDialogState();
}

class _CalculatorDialogState extends State<_CalculatorDialog> {
  final _input = TextEditingController();
  final _focus = FocusNode();
  final _history = <({String expr, String result})>[];

  String _result = '';
  String? _error;

  @override
  void initState() {
    super.initState();
    _input.addListener(_recompute);
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _input.removeListener(_recompute);
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _recompute() {
    final expr = _input.text.trim();
    if (expr.isEmpty) {
      setState(() {
        _result = '';
        _error = null;
      });
      return;
    }
    try {
      setState(() {
        _result = CalcEvaluator.formatResult(CalcEvaluator.eval(expr));
        _error = null;
      });
    } on CalcException catch (e) {
      setState(() {
        _result = '';
        _error = e.message;
      });
    } catch (_) {
      setState(() {
        _result = '';
        _error = 'Invalid expression';
      });
    }
  }

  void _append(String token) {
    final sel = _input.selection;
    final text = _input.text;
    final start = sel.isValid ? sel.start : text.length;
    final end = sel.isValid ? sel.end : text.length;
    final next = text.replaceRange(start, end, token);
    _input.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: start + token.length),
    );
  }

  void _backspace() {
    final sel = _input.selection;
    final text = _input.text;
    if (text.isEmpty) return;
    if (sel.isValid && sel.start != sel.end) {
      final next = text.replaceRange(sel.start, sel.end, '');
      _input.value = TextEditingValue(
        text: next,
        selection: TextSelection.collapsed(offset: sel.start),
      );
      return;
    }
    final caret = sel.isValid ? sel.start : text.length;
    if (caret == 0) return;
    final next = text.replaceRange(caret - 1, caret, '');
    _input.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: caret - 1),
    );
  }

  void _clear() {
    _input.clear();
  }

  void _equals() {
    final expr = _input.text.trim();
    if (expr.isEmpty || _result.isEmpty) return;
    setState(() {
      _history.insert(0, (expr: expr, result: _result));
      if (_history.length > 8) _history.removeLast();
      _input.value = TextEditingValue(
        text: _result,
        selection: TextSelection.collapsed(offset: _result.length),
      );
    });
  }

  void _insert() {
    if (_result.isEmpty) return;
    widget.onInsert?.call(_result);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = Theme.of(context).colorScheme.primary;
    final surface = isDark ? const Color(0xFF1A1A1A) : Colors.white;
    final fieldBg = isDark ? const Color(0xFF0D0D0D) : const Color(0xFFF5F5F5);
    final textColor = isDark ? const Color(0xFFE0E0E0) : const Color(0xFF1A1A1A);
    final muted = isDark ? const Color(0xFF808080) : const Color(0xFF999999);

    return Dialog(
      backgroundColor: surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.calculate_outlined, size: 18, color: accent),
                  const SizedBox(width: 8),
                  Text('Calculator',
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: textColor)),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Close',
                    icon: Icon(Icons.close, size: 18, color: muted),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // Expression field
              Container(
                decoration: BoxDecoration(
                  color: fieldBg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                      color: isDark
                          ? const Color(0xFF2A2A2A)
                          : const Color(0xFFE0E0E0)),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Shortcuts(
                      shortcuts: const {
                        SingleActivator(LogicalKeyboardKey.enter):
                            _EqualsIntent(),
                        SingleActivator(LogicalKeyboardKey.numpadEnter):
                            _EqualsIntent(),
                      },
                      child: Actions(
                        actions: {
                          _EqualsIntent: CallbackAction<_EqualsIntent>(
                            onInvoke: (_) {
                              _equals();
                              return null;
                            },
                          ),
                        },
                        child: TextField(
                          controller: _input,
                          focusNode: _focus,
                          autofocus: true,
                          style: TextStyle(
                            fontFamily: 'Consolas',
                            fontSize: 20,
                            color: textColor,
                          ),
                          decoration: InputDecoration(
                            border: InputBorder.none,
                            hintText: '0',
                            hintStyle: TextStyle(color: muted, fontSize: 20),
                            isDense: true,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 2),
                    SizedBox(
                      height: 22,
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: Text(
                          _error ?? (_result.isEmpty ? '' : '= $_result'),
                          style: TextStyle(
                            fontFamily: 'Consolas',
                            fontSize: 14,
                            color: _error != null ? const Color(0xFFE57373) : accent,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              _buildKeypad(isDark, accent, textColor),
              if (_history.isNotEmpty) ...[
                const SizedBox(height: 12),
                _buildHistory(muted, textColor),
              ],
              if (widget.onInsert != null) ...[
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _result.isEmpty ? null : _insert,
                    icon: const Icon(Icons.input, size: 16),
                    label: const Text('Insert result'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildKeypad(bool isDark, Color accent, Color textColor) {
    // Each entry: label, onTap, and an optional flag for accent styling.
    final rows = <List<_Key>>[
      [
        _Key('C', _clear, kind: _KeyKind.action),
        _Key('(', () => _append('(')),
        _Key(')', () => _append(')')),
        _Key('⌫', _backspace, kind: _KeyKind.action),
      ],
      [
        _Key('7', () => _append('7')),
        _Key('8', () => _append('8')),
        _Key('9', () => _append('9')),
        _Key('÷', () => _append('÷'), kind: _KeyKind.op),
      ],
      [
        _Key('4', () => _append('4')),
        _Key('5', () => _append('5')),
        _Key('6', () => _append('6')),
        _Key('×', () => _append('×'), kind: _KeyKind.op),
      ],
      [
        _Key('1', () => _append('1')),
        _Key('2', () => _append('2')),
        _Key('3', () => _append('3')),
        _Key('-', () => _append('-'), kind: _KeyKind.op),
      ],
      [
        _Key('0', () => _append('0')),
        _Key('.', () => _append('.')),
        _Key('^', () => _append('^'), kind: _KeyKind.op),
        _Key('+', () => _append('+'), kind: _KeyKind.op),
      ],
      [
        _Key('%', () => _append('%'), kind: _KeyKind.op),
        _Key('=', _equals, kind: _KeyKind.equals, flex: 3),
      ],
    ];

    return Column(
      children: [
        for (final row in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                for (final key in row) ...[
                  Expanded(
                    flex: key.flex,
                    child: _CalcButton(
                      label: key.label,
                      onTap: key.onTap,
                      kind: key.kind,
                      isDark: isDark,
                      accent: accent,
                      textColor: textColor,
                    ),
                  ),
                  if (key != row.last) const SizedBox(width: 6),
                ],
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildHistory(Color muted, Color textColor) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Recent',
            style: TextStyle(fontSize: 11, color: muted, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        ..._history.take(4).map((h) => InkWell(
              onTap: () {
                _input.value = TextEditingValue(
                  text: h.result,
                  selection:
                      TextSelection.collapsed(offset: h.result.length),
                );
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                  '${h.expr} = ${h.result}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'Consolas',
                    fontSize: 12,
                    color: textColor.withValues(alpha: 0.75),
                  ),
                ),
              ),
            )),
      ],
    );
  }
}

enum _KeyKind { digit, op, action, equals }

class _Key {
  final String label;
  final VoidCallback onTap;
  final _KeyKind kind;
  final int flex;
  _Key(this.label, this.onTap, {this.kind = _KeyKind.digit, this.flex = 1});
}

class _CalcButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final _KeyKind kind;
  final bool isDark;
  final Color accent;
  final Color textColor;

  const _CalcButton({
    required this.label,
    required this.onTap,
    required this.kind,
    required this.isDark,
    required this.accent,
    required this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    Color bg;
    Color fg;
    switch (kind) {
      case _KeyKind.equals:
        bg = accent;
        fg = Colors.white;
        break;
      case _KeyKind.op:
        bg = accent.withValues(alpha: 0.14);
        fg = accent;
        break;
      case _KeyKind.action:
        bg = isDark ? const Color(0xFF2A2A2A) : const Color(0xFFEAEAEA);
        fg = isDark ? const Color(0xFFD0D0D0) : const Color(0xFF555555);
        break;
      case _KeyKind.digit:
        bg = isDark ? const Color(0xFF222222) : const Color(0xFFF0F0F0);
        fg = textColor;
        break;
    }

    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          height: 44,
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 18,
              fontWeight:
                  kind == _KeyKind.equals ? FontWeight.w700 : FontWeight.w500,
              color: fg,
            ),
          ),
        ),
      ),
    );
  }
}

class _EqualsIntent extends Intent {
  const _EqualsIntent();
}
