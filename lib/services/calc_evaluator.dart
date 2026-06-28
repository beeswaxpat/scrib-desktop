/// A small, dependency-free arithmetic evaluator for the built-in calculator.
///
/// It is a hand-written recursive-descent parser, deliberately not `eval` or a
/// third-party package: the input is parsed into numbers and a fixed set of
/// operators only, so a note can never smuggle code through the calculator.
///
/// Supported grammar (highest precedence last):
///   expr   := term   (('+' | '-') term)*
///   term   := power  (('*' | '/' | '%' | '×' | '÷') power)*
///   power  := unary  ('^' power)?              // right-associative
///   unary  := ('+' | '-') unary | primary
///   primary:= number | '(' expr ')'
///
/// Numbers may be integers or decimals (`12`, `3.14`, `.5`). Whitespace and
/// thousands separators (`,` and `_`) are ignored.
library;

import 'dart:math' as math;

/// Raised when an expression cannot be evaluated. [message] is user-facing.
class CalcException implements Exception {
  final String message;
  CalcException(this.message);
  @override
  String toString() => message;
}

class CalcEvaluator {
  final String _src;
  int _pos = 0;

  CalcEvaluator._(this._src);

  /// Evaluates [expression] and returns the numeric result.
  /// Throws [CalcException] on empty, malformed, or undefined input.
  static double eval(String expression) {
    final parser = CalcEvaluator._(expression);
    return parser._run();
  }

  /// Evaluates [expression] and returns a trimmed display string, or null if it
  /// cannot be evaluated. Never throws, so it is safe for live "as you type".
  static String? tryEvalToString(String expression) {
    try {
      return formatResult(eval(expression));
    } catch (_) {
      return null;
    }
  }

  /// Formats a result without trailing zeros: 4.0 -> "4", 2.5 -> "2.5".
  static String formatResult(double value) {
    if (value.isNaN) throw CalcException('Not a number');
    if (value.isInfinite) throw CalcException('Result is too large');
    if (value == value.roundToDouble() && value.abs() < 1e15) {
      return value.toInt().toString();
    }
    final s = value.toStringAsPrecision(12);
    if (s.contains('e')) {
      // Scientific notation (large/small magnitudes): trim trailing zeros in the
      // mantissa only, never the exponent (stripping exponent zeros would change
      // the value, e.g. 1e+20 -> 1e+2).
      final parts = s.split('e');
      final mantissa = _trimDecimalZeros(parts[0]);
      return '${mantissa}e${parts[1]}';
    }
    return _trimDecimalZeros(s);
  }

  static String _trimDecimalZeros(String s) {
    if (!s.contains('.')) return s;
    return s
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
  }

  double _run() {
    _skipWs();
    if (_pos >= _src.length) {
      throw CalcException('Enter an expression');
    }
    final result = _expr();
    _skipWs();
    if (_pos < _src.length) {
      throw CalcException('Unexpected "${_src[_pos]}"');
    }
    return result;
  }

  double _expr() {
    var left = _term();
    while (true) {
      _skipWs();
      final op = _peek();
      if (op == '+') {
        _pos++;
        left += _term();
      } else if (op == '-') {
        _pos++;
        left -= _term();
      } else {
        return left;
      }
    }
  }

  double _term() {
    var left = _power();
    while (true) {
      _skipWs();
      final op = _peek();
      if (op == '*' || op == '×') {
        _pos++;
        left *= _power();
      } else if (op == '/' || op == '÷') {
        _pos++;
        final right = _power();
        if (right == 0) throw CalcException('Cannot divide by zero');
        left /= right;
      } else if (op == '%') {
        _pos++;
        final right = _power();
        if (right == 0) throw CalcException('Cannot divide by zero');
        left = left % right;
      } else {
        return left;
      }
    }
  }

  double _power() {
    final base = _unary();
    _skipWs();
    if (_peek() == '^') {
      _pos++;
      final exponent = _power(); // right-associative
      final result = _pow(base, exponent);
      if (result.isNaN) throw CalcException('Undefined result');
      return result;
    }
    return base;
  }

  double _unary() {
    _skipWs();
    final c = _peek();
    if (c == '-') {
      _pos++;
      return -_unary();
    }
    if (c == '+') {
      _pos++;
      return _unary();
    }
    return _primary();
  }

  double _primary() {
    _skipWs();
    final c = _peek();
    if (c == '(') {
      _pos++;
      final value = _expr();
      _skipWs();
      if (_peek() != ')') {
        throw CalcException('Missing ")"');
      }
      _pos++;
      return value;
    }
    return _number();
  }

  double _number() {
    final sb = StringBuffer();
    var sawDigit = false;
    var sawDot = false;
    while (_pos < _src.length) {
      final ch = _src[_pos];
      if (_isDigit(ch)) {
        sawDigit = true;
        sb.write(ch);
        _pos++;
      } else if (ch == '.') {
        if (sawDot) break;
        sawDot = true;
        sb.write(ch);
        _pos++;
      } else if (ch == ',' || ch == '_') {
        // Thousands separators are ignored within a number (1,000 -> 1000).
        _pos++;
      } else {
        break;
      }
    }
    if (!sawDigit) {
      if (_pos >= _src.length) throw CalcException('Unexpected end');
      throw CalcException('Unexpected "${_src[_pos]}"');
    }
    final text = sb.toString();
    final value = double.tryParse(text);
    if (value == null) throw CalcException('Invalid number "$text"');
    return value;
  }

  static double _pow(double base, double exp) {
    // dart:math pow returns num; cast to double, surfacing NaN for cases like
    // (-8)^0.5 which we treat as undefined.
    return math.pow(base, exp).toDouble();
  }

  String? _peek() => _pos < _src.length ? _src[_pos] : null;

  void _skipWs() {
    while (_pos < _src.length) {
      final ch = _src[_pos];
      if (ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r') {
        _pos++;
      } else {
        break;
      }
    }
  }

  static bool _isDigit(String ch) {
    final code = ch.codeUnitAt(0);
    return code >= 0x30 && code <= 0x39;
  }
}
