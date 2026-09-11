import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/server_config.dart';

/// `SERVER_HOST`/`SERVER_PORT` are compile-time `--dart-define`s, so a test
/// process cannot flip them at runtime — it only ever sees whatever this test
/// BUILD was given (the default 443/production host, absent an override).
/// What is testable, and what actually matters, is the *derivation*: TLS is
/// inferred from the port, never configured separately, so a 443 port must
/// always agree with https/wss and any other port with http/ws. Asserting
/// that agreement — rather than a hardcoded host — is what a mutation of
/// `kServerSecure`'s `== 443` would actually break.
void main() {
  group('server_config', () {
    test('kHttpBase agrees with kServerSecure', () {
      final expectedScheme = kServerSecure ? 'https' : 'http';
      expect(kHttpBase, '$expectedScheme://$kServerHost:$kServerPort');
    });

    test('kSocketUrl agrees with kServerSecure', () {
      final expectedScheme = kServerSecure ? 'wss' : 'ws';
      final url = kSocketUrl('a-token');
      expect(
        url,
        '$expectedScheme://$kServerHost:$kServerPort'
        '/socket/websocket?vsn=2.0.0&token=a-token',
      );
    });

    test('kServerSecure is true only for port 443', () {
      expect(kServerSecure, kServerPort == 443);
    });

    test('the default build (no --dart-define override) is TLS on 443', () {
      // This is the one place a literal is safe to assert: it is the
      // DEFAULT this file falls back to, not a live server address, and it
      // is exactly what a `flutter test` run (no --dart-define) sees.
      expect(kServerPort, 443);
      expect(kServerHost, 'ai.clausens.cloud');
      expect(kServerSecure, isTrue);
      expect(kHttpBase, 'https://ai.clausens.cloud:443');
    });
  });
}
