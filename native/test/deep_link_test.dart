import 'package:flutter_test/flutter_test.dart';
import 'package:henry_wall/deep_link.dart';

void main() {
  group('parseConnectorsLink', () {
    test('reads a success status', () {
      expect(
        parseConnectorsLink(Uri.parse('henry://connectors?status=ok')),
        ConnectorsOauthResult.ok,
      );
    });

    test('reads a failure status', () {
      expect(
        parseConnectorsLink(Uri.parse('henry://connectors?status=error')),
        ConnectorsOauthResult.failed,
      );
    });

    // The scheme is open to every app on the device (see the library doc). These four are the
    // shapes a caller other than our own server would produce, and every one of them must come
    // back null rather than being read as a connection that succeeded.
    test('ignores another app scheme', () {
      expect(parseConnectorsLink(Uri.parse('other://connectors?status=ok')), isNull);
    });

    test('ignores an unknown host', () {
      expect(parseConnectorsLink(Uri.parse('henry://something?status=ok')), isNull);
    });

    test('ignores an unknown status rather than assuming success', () {
      expect(parseConnectorsLink(Uri.parse('henry://connectors?status=maybe')), isNull);
    });

    test('ignores a link with no status at all', () {
      expect(parseConnectorsLink(Uri.parse('henry://connectors')), isNull);
    });
  });
}
