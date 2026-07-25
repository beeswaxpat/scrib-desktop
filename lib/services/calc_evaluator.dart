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
/// Numbers may be integers, decimals, or scientific notation (`12`, `3.14`,
/// `.5`, `1e+21`, `2.5e-3`). Whitespace and thousands separators (`,` and `_`)
/// are ignored. Parse depth is capped so pathological nesting raises a
/// [CalcException] instead of overflowing the stack, and a `^` whose result
/// overflows raises one too, so a runaway tower like `9^9^9` is an error
/// rather than an infinity travelling on through the rest of the expression.
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
      final exponent = _guard(_power); // right-associative
      final result = _pow(base, exponent);
      if (result.isNaN) throw CalcException('Undefined result');
      // A runaway tower like 9^9^9 overflows to infinity here. Reporting it at
      // the point of the overflow, rather than letting infinity propagate for
      // formatResult to reject later, means eval() itself never hands a caller
      // a number no arithmetic below it can use.
      if (result.isInfinite) throw CalcException('Result is too large');
      return result;
    }
    return base;
  }

  /// Parse depth cap: pasted garbage like '(' * 20000 or a 20000-long '^'
  /// chain raises a CalcException instead of a StackOverflowError, which
  /// callers that only catch CalcException could not survive. Guarding
  /// [_unary] bounds the parenthesis cycle (_primary -> _expr -> ... ->
  /// _unary) and chained unary signs; the '^' right-recursion in [_power]
  /// happens after its _unary call has already unwound, so it is guarded
  /// separately at the call site.
  static const int _maxDepth = 500;
  int _depth = 0;

  double _guard(double Function() body) {
    _depth++;
    if (_depth > _maxDepth) {
      throw CalcException('Expression is too deeply nested');
    }
    try {
      return body();
    } finally {
      _depth--;
    }
  }

  double _unary() => _guard(() {
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
      });

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
    // Optional exponent (scientific notation): 'e' or 'E', an optional sign,
    // then at least one digit (1e21, 1e+21, 2.5e-3). The '=' key and history
    // taps feed formatResult output back into the input, so the parser must
    // accept everything formatResult can emit. A dangling 'e' ("2e", "2e+")
    // is left unconsumed and stays an error, exactly as before.
    if (_pos < _src.length && (_src[_pos] == 'e' || _src[_pos] == 'E')) {
      var look = _pos + 1;
      var sign = '';
      if (look < _src.length && (_src[look] == '+' || _src[look] == '-')) {
        sign = _src[look];
        look++;
      }
      if (look < _src.length && _isDigit(_src[look])) {
        sb.write('e');
        sb.write(sign);
        _pos = look;
        while (_pos < _src.length && _isDigit(_src[_pos])) {
          sb.write(_src[_pos]);
          _pos++;
        }
      }
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
