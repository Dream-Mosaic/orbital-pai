import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/deep_link.dart';

void main() {
  group('parseAppLink: connectors', () {
    test('reads a success status', () {
      final link = parseAppLink(Uri.parse('orbital://connectors?status=ok'));
      expect(link, isA<ConnectorsResultLink>());
      expect((link as ConnectorsResultLink).result, ConnectorsOauthResult.ok);
    });

    test('reads a failure status', () {
      final link =
          parseAppLink(Uri.parse('orbital://connectors?status=error'));
      expect(link, isA<ConnectorsResultLink>());
      expect(
          (link as ConnectorsResultLink).result, ConnectorsOauthResult.failed);
    });

    // The scheme is open to every app on the device (see the library doc). These four are the
    // shapes a caller other than our own server would produce, and every one of them must come
    // back null rather than being read as a connection that succeeded.
    test('ignores another app scheme', () {
      expect(parseAppLink(Uri.parse('other://connectors?status=ok')), isNull);
    });

    test('ignores an unknown host', () {
      expect(
          parseAppLink(Uri.parse('orbital://something?status=ok')), isNull);
    });

    test('ignores an unknown status rather than assuming success', () {
      expect(parseAppLink(Uri.parse('orbital://connectors?status=maybe')),
          isNull);
    });

    test('ignores a link with no status at all', () {
      expect(parseAppLink(Uri.parse('orbital://connectors')), isNull);
    });
  });

  group('parseAppLink: auth', () {
    test('reads a valid single-use code', () {
      final link = parseAppLink(Uri.parse('orbital://auth?code=abc'));
      expect(link, isA<AuthCodeLink>());
      expect((link as AuthCodeLink).code, 'abc');
    });

    test('reads an error status', () {
      expect(parseAppLink(Uri.parse('orbital://auth?status=error')),
          isA<AuthErrorLink>());
    });

    test('ignores a link with no code at all', () {
      expect(parseAppLink(Uri.parse('orbital://auth')), isNull);
    });

    test('ignores an empty code', () {
      expect(parseAppLink(Uri.parse('orbital://auth?code=')), isNull);
    });

    test('ignores an absurdly long code', () {
      final hostileCode = 'a' * 513;
      expect(
          parseAppLink(Uri.parse('orbital://auth?code=$hostileCode')), isNull);
    });

    test('accepts a code right at the cap', () {
      final code = 'a' * 512;
      final link = parseAppLink(Uri.parse('orbital://auth?code=$code'));
      expect(link, isA<AuthCodeLink>());
      expect((link as AuthCodeLink).code, code);
    });

    test('ignores another app scheme', () {
      expect(parseAppLink(Uri.parse('other://auth?code=abc')), isNull);
    });
  });
}
