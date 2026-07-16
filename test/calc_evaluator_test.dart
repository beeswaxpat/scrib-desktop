import 'package:flutter_test/flutter_test.dart';
import 'package:scrib_desktop/services/calc_evaluator.dart';

/// The built-in calculator's expression evaluator: precedence, associativity,
/// decimals, and the error cases that keep it from accepting junk.
void main() {
  double eval(String s) => CalcEvaluator.eval(s);

  group('basic arithmetic', () {
    test('addition and subtraction', () {
      expect(eval('2 + 3'), 5);
      expect(eval('10 - 4 - 1'), 5);
    });

    test('multiplication and division', () {
      expect(eval('6 * 7'), 42);
      expect(eval('10 / 4'), 2.5);
    });

    test('unicode operators × and ÷', () {
      expect(eval('6 × 7'), 42);
      expect(eval('9 ÷ 3'), 3);
    });

    test('modulo', () {
      expect(eval('10 % 3'), 1);
      expect(eval('10.5 % 2'), closeTo(0.5, 1e-9));
    });
  });

  group('precedence and associativity', () {
    test('multiplication before addition', () {
      expect(eval('2 + 3 * 4'), 14);
    });

    test('parentheses override precedence', () {
      expect(eval('(2 + 3) * 4'), 20);
    });

    test('power is right-associative', () {
      expect(eval('2 ^ 3 ^ 2'), 512); // 2^(3^2), not (2^3)^2 = 64
    });

    test('power before multiplication', () {
      expect(eval('2 * 3 ^ 2'), 18);
    });

    test('nested parentheses', () {
      expect(eval('((1 + 2) * (3 + 4))'), 21);
    });
  });

  group('unary and decimals', () {
    test('leading minus', () {
      expect(eval('-5 + 2'), -3);
    });

    test('minus after operator', () {
      expect(eval('2 * -3'), -6);
      expect(eval('2 - -3'), 5);
    });

    test('decimals', () {
      expect(eval('3.14 * 2'), closeTo(6.28, 1e-9));
      expect(eval('.5 + .5'), 1);
    });

    test('separators are ignored', () {
      expect(eval('1,000 + 1'), 1001);
      expect(eval('1_000 * 2'), 2000);
    });
  });

  group('errors', () {
    test('division by zero', () {
      expect(() => eval('1 / 0'), throwsA(isA<CalcException>()));
      expect(() => eval('5 % 0'), throwsA(isA<CalcException>()));
    });

    test('empty input', () {
      expect(() => eval(''), throwsA(isA<CalcException>()));
      expect(() => eval('   '), throwsA(isA<CalcException>()));
    });

    test('trailing operator', () {
      expect(() => eval('2 +'), throwsA(isA<CalcException>()));
    });

    test('unbalanced parentheses', () {
      expect(() => eval('(2 + 3'), throwsA(isA<CalcException>()));
      expect(() => eval('2 + 3)'), throwsA(isA<CalcException>()));
    });

    test('letters rejected (no eval, no code)', () {
      expect(() => eval('abc'), throwsA(isA<CalcException>()));
      expect(() => eval('2 + foo'), throwsA(isA<CalcException>()));
    });

    test('no implicit multiplication', () {
      expect(() => eval('2(3)'), throwsA(isA<CalcException>()));
    });
  });

  group('formatting', () {
    test('integers drop the decimal', () {
      expect(CalcEvaluator.formatResult(4.0), '4');
      expect(CalcEvaluator.formatResult(-7.0), '-7');
    });

    test('decimals trim trailing zeros', () {
      expect(CalcEvaluator.formatResult(2.5), '2.5');
      expect(CalcEvaluator.formatResult(2.50), '2.5');
    });

    test('tryEvalToString never throws', () {
      expect(CalcEvaluator.tryEvalToString('2 + 2'), '4');
      expect(CalcEvaluator.tryEvalToString('garbage'), isNull);
      expect(CalcEvaluator.tryEvalToString('1/0'), isNull);
    });

    test('scientific notation keeps its exponent (no corruption)', () {
      // Regression: the trailing-zero trim must never touch the exponent, or
      // 1e20 would format as 1e+2 and a wildly wrong number lands in the note.
      for (final v in [1e20, 1e30, 1e-10, 5e16]) {
        final s = CalcEvaluator.formatResult(v);
        expect(double.parse(s), v, reason: 'formatResult($v) -> $s');
      }
    });

    test('powers that overflow into scientific notation stay correct', () {
      expect(double.parse(CalcEvaluator.tryEvalToString('10 ^ 20')!), 1e20);
      expect(double.parse(CalcEvaluator.tryEvalToString('10 ^ 30')!), 1e30);
    });
  });

  group('scientific notation input', () {
    test('e-notation numbers parse', () {
      expect(eval('1e21'), 1e21);
      expect(eval('1e+21'), 1e21);
      expect(eval('2.5e-3'), closeTo(0.0025, 1e-15));
      expect(eval('1E6'), 1e6);
      expect(eval('.5e3'), 500);
    });

    test('e-notation participates in arithmetic', () {
      expect(eval('1e3 + 1'), 1001);
      expect(eval('2 * 1e-1'), closeTo(0.2, 1e-12));
      expect(eval('-1e+21'), -1e21);
    });

    test('bare or dangling e is still rejected', () {
      expect(() => eval('e5'), throwsA(isA<CalcException>()));
      expect(() => eval('2e'), throwsA(isA<CalcException>()));
      expect(() => eval('2e+'), throwsA(isA<CalcException>()));
      expect(() => eval('2e-'), throwsA(isA<CalcException>()));
    });

    test('every result the calculator can display is re-parseable (= chains)', () {
      // Regression: the '=' key and history taps feed formatResult output back
      // into the input field, so eval must round-trip formatResult. Before the
      // exponent fix, '9 ^ 22' then '=' produced '9.84770902184e+20' and the
      // calculator rejected its own result with 'Unexpected "e"'.
      const exprs = [
        '9 ^ 22',
        '10 ^ 30',
        '1 / 3',
        '2 ^ -40',
        '-(10 ^ 25)',
        '0.1 + 0.2',
        '2 + 2',
      ];
      for (final expr in exprs) {
        final shown = CalcEvaluator.formatResult(CalcEvaluator.eval(expr));
        final rechained = CalcEvaluator.tryEvalToString(shown);
        expect(rechained, shown, reason: '$expr displays "$shown" which must re-parse to itself');
      }
    });
  });

  group('power edge cases', () {
    test('fractional power of a negative base throws CalcException, not NaN', () {
      expect(() => eval('(-8) ^ 0.5'), throwsA(isA<CalcException>()));
      expect(CalcEvaluator.tryEvalToString('(-8) ^ 0.5'), isNull);
    });

    test('negative exponent works', () {
      expect(eval('2 ^ -2'), 0.25);
    });

    test('0 ^ 0 evaluates to 1 (pinned)', () {
      expect(eval('0 ^ 0'), 1);
    });

    test('infinite results are rejected at format time, never displayed', () {
      expect(() => CalcEvaluator.formatResult(CalcEvaluator.eval('10 ^ 999')),
          throwsA(isA<CalcException>()));
      expect(CalcEvaluator.tryEvalToString('10 ^ 999'), isNull);
    });
  });

  group('deep nesting robustness', () {
    test('pathological parens throw CalcException, not StackOverflowError', () {
      final deep = '${'(' * 20000}1${')' * 20000}';
      expect(() => eval(deep), throwsA(isA<CalcException>()));
      expect(CalcEvaluator.tryEvalToString(deep), isNull);
    });

    test('long chains of unary signs are bounded', () {
      expect(() => eval('${'-' * 20000}1'), throwsA(isA<CalcException>()));
    });

    test('long chains of ^ are bounded', () {
      expect(() => eval(List.filled(20000, '2').join('^')),
          throwsA(isA<CalcException>()));
    });

    test('reasonable nesting still works', () {
      expect(eval('${'(' * 100}7${')' * 100}'), 7);
      expect(eval('---5'), -5);
    });

    test('long flat expressions are not depth-limited', () {
      // The depth counter must unwind between terms: 2000 additions in a row
      // never nest, so they must not trip the cap.
      expect(eval(List.filled(2000, '1').join('+')), 2000);
    });
  });
}
