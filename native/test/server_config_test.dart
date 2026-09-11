import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/server_config.dart';

/// `SERVER_HOST`/`SERVER_PORT` are compile-time `--dart-define`s, so a test
/// process cannot flip them at runtime — it only ever sees whatever this test
/// BUILD was given (the default 443/production host, absent an override).
///
/// That is why the derivation is tested through the pure `secureForPort` /
/// `httpBaseFor` / `socketUrlFor` helpers rather than only through the
/// `kServer*` constants: a test that derives its own "expected" value FROM
/// `kServerSecure` is tautological under any mutation of `kServerSecure`
/// itself (`bool get kServerSecure => true` passed the earlier version of
/// this file's whole suite). Driving the helpers directly, at ports this
/// build's `--dart-define`s can never touch, is what actually puts the
/// `== 443` under test.
void main() {
  group('secureForPort', () {
    test('443 is secure', () {
      expect(secureForPort(443), isTrue);
    });

    test('8787 (the dev server) is not secure', () {
      expect(secureForPort(8787), isFalse);
    });

    test('80 is not secure', () {
      expect(secureForPort(80), isFalse);
    });
  });

  group('httpBaseFor', () {
    test('443 -> https', () {
      expect(httpBaseFor('example.com', 443), 'https://example.com:443');
    });

    test('8787 -> http', () {
      expect(httpBaseFor('127.0.0.1', 8787), 'http://127.0.0.1:8787');
    });

    test('80 -> http', () {
      expect(httpBaseFor('example.com', 80), 'http://example.com:80');
    });
  });

  group('socketUrlFor', () {
    test('443 -> wss', () {
      expect(
        socketUrlFor('example.com', 443, 'tok'),
        'wss://example.com:443/socket/websocket?vsn=2.0.0&token=tok',
      );
    });

    test('8787 -> ws', () {
      expect(
        socketUrlFor('127.0.0.1', 8787, 'tok'),
        'ws://127.0.0.1:8787/socket/websocket?vsn=2.0.0&token=tok',
      );
    });

    test('80 -> ws', () {
      expect(
        socketUrlFor('example.com', 80, 'tok'),
        'ws://example.com:80/socket/websocket?vsn=2.0.0&token=tok',
      );
    });
  });

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
