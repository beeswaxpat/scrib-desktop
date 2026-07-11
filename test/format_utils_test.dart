import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:scrib_desktop/services/format_utils.dart';

void main() {
  group('resolveListToggle', () {
    test('no list -> clicking bullet applies bullet', () {
      final result = resolveListToggle(null, Attribute.ul);
      expect(result.key, Attribute.list.key);
      expect(result.value, 'bullet');
    });

    test('bullet -> clicking bullet removes the list', () {
      final result = resolveListToggle('bullet', Attribute.ul);
      expect(result.key, Attribute.list.key);
      expect(result.value, isNull);
    });

    test('numbered -> clicking bullet SWITCHES to bullet (not remove)', () {
      final result = resolveListToggle('ordered', Attribute.ul);
      expect(result.value, 'bullet');
    });

    test('bullet -> clicking numbered switches to numbered', () {
      final result = resolveListToggle('bullet', Attribute.ol);
      expect(result.value, 'ordered');
    });

    test('checklist toggles off against unchecked', () {
      final result = resolveListToggle('unchecked', Attribute.unchecked);
      expect(result.value, isNull);
    });

    test('bullet -> checklist switches', () {
      final result = resolveListToggle('bullet', Attribute.unchecked);
      expect(result.value, 'unchecked');
    });
  });

  group('normalizeLinkUrl', () {
    test('accepts http, https, and mailto as-is', () {
      expect(normalizeLinkUrl('https://example.com/x'), 'https://example.com/x');
      expect(normalizeLinkUrl('http://example.com'), 'http://example.com');
      expect(normalizeLinkUrl('mailto:a@b.com'), 'mailto:a@b.com');
    });

    test('trims whitespace', () {
      expect(normalizeLinkUrl('  https://example.com  '), 'https://example.com');
    });

    test('bare domain gets https', () {
      expect(normalizeLinkUrl('example.com'), 'https://example.com');
      expect(normalizeLinkUrl('example.com/path?q=1'), 'https://example.com/path?q=1');
    });

    test('host with port is not mistaken for a scheme', () {
      expect(normalizeLinkUrl('example.com:8080/x'), 'https://example.com:8080/x');
    });

    test('bare email gets mailto', () {
      expect(normalizeLinkUrl('a@b.com'), 'mailto:a@b.com');
    });

    test('rejects active or unknown schemes', () {
      expect(normalizeLinkUrl('javascript:alert(1)'), isNull);
      expect(normalizeLinkUrl('file:///C:/secret.txt'), isNull);
      expect(normalizeLinkUrl('data:text/html,x'), isNull);
      expect(normalizeLinkUrl('ftp://example.com'), isNull);
    });

    test('rejects empty, spaces, and non-URLs', () {
      expect(normalizeLinkUrl(''), isNull);
      expect(normalizeLinkUrl('   '), isNull);
      expect(normalizeLinkUrl('not a url'), isNull);
      expect(normalizeLinkUrl('word'), isNull);
    });
  });

  group('isSafeLaunchUrl', () {
    test('allows only http, https, mailto', () {
      expect(isSafeLaunchUrl('https://example.com'), isTrue);
      expect(isSafeLaunchUrl('http://example.com'), isTrue);
      expect(isSafeLaunchUrl('mailto:a@b.com'), isTrue);
      expect(isSafeLaunchUrl('javascript:alert(1)'), isFalse);
      expect(isSafeLaunchUrl('file:///C:/x'), isFalse);
      expect(isSafeLaunchUrl(''), isFalse);
    });
  });
}
