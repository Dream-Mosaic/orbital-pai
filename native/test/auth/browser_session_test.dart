import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/auth/browser_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('flutter_web_auth_2');

  group('WebAuthBrowserSession', () {
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('resolves the callback url the platform hands back', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'authenticate');
        expect(call.arguments['callbackUrlScheme'], 'orbital');
        return 'orbital://auth?code=abc';
      });

      final uri = await const WebAuthBrowserSession()
          .run(Uri.parse('https://example.test/auth/login?return=app'));

      expect(uri, Uri.parse('orbital://auth?code=abc'));
    });

    test('a dismissed sheet (CANCELED) resolves null, not an error', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'CANCELED');
      });

      final uri = await const WebAuthBrowserSession()
          .run(Uri.parse('https://example.test/auth/login?return=app'));

      expect(uri, isNull);
    });

    test('any other platform failure propagates', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'FAILED');
      });

      expect(
        () => const WebAuthBrowserSession()
            .run(Uri.parse('https://example.test/auth/login?return=app')),
        throwsA(isA<PlatformException>()),
      );
    });
  });
}
