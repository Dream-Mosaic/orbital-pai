import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:orbital_pai/auth/auth_controller.dart';
import 'package:orbital_pai/auth/token_store.dart';
import 'package:orbital_pai/deep_link.dart';
import 'package:orbital_pai/server_config.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import '../support/fake_url_launcher.dart';

void main() {
  group('AuthController', () {
    late TestFlutterSecureStoragePlatform fakePlatform;
    late TokenStore store;

    setUp(() {
      fakePlatform = TestFlutterSecureStoragePlatform(<String, String>{});
      FlutterSecureStoragePlatform.instance = fakePlatform;
      store = TokenStore(storage: const FlutterSecureStorage());
      FakeUrlLauncher.register();
    });

    AuthController build({http.Client? httpClient}) =>
        AuthController(store: store, httpClient: httpClient);

    test('starts unknown, then settles to signedIn with a stored token',
        () async {
      await store.write('stored-token');
      final auth = build();

      expect(auth.state, AuthState.unknown);
      await auth.ready;

      expect(auth.state, AuthState.signedIn);
      expect(auth.token, 'stored-token');
    });

    test('starts unknown, then settles to signedOut with no stored token',
        () async {
      final auth = build();

      expect(auth.state, AuthState.unknown);
      await auth.ready;

      expect(auth.state, AuthState.signedOut);
      expect(auth.token, isNull);
    });

    test('signIn opens /auth/login?return=app in the EXTERNAL browser',
        () async {
      final auth = build();
      await auth.ready;

      final fake = FakeUrlLauncher.register();
      await auth.signIn();

      expect(fake.launches, hasLength(1));
      // Compared as a Uri, not a literal string: `Uri.parse` drops an
      // explicit port that matches its scheme's default (443 for https), so
      // the string this app builds and the string a naive literal would
      // predict legitimately differ in exactly that case.
      expect(Uri.parse(fake.launches.single.url),
          Uri.parse('$kHttpBase/auth/login?return=app'));
      expect(fake.launches.single.mode, PreferredLaunchMode.externalApplication);
    });

    test('an AuthCodeLink on 200 writes the token and becomes signedIn',
        () async {
      final client = MockClient((request) async {
        expect(request.url, Uri.parse('$kHttpBase/api/auth/exchange'));
        expect(jsonDecode(request.body), {'code': 'the-code'});
        return http.Response(jsonEncode({'token': 'real-token'}), 200);
      });
      final auth = build(httpClient: client);
      await auth.ready;

      await auth.handleLink(const AuthCodeLink('the-code'));

      expect(auth.state, AuthState.signedIn);
      expect(auth.token, 'real-token');
      expect(await store.read(), 'real-token');
    });

    test('an AuthCodeLink on 401 stays signedOut and writes nothing',
        () async {
      final client = MockClient((request) async {
        return http.Response(jsonEncode({'error': 'invalid_code'}), 401);
      });
      final auth = build(httpClient: client);
      await auth.ready;

      await auth.handleLink(const AuthCodeLink('bad-code'));

      expect(auth.state, AuthState.signedOut);
      expect(auth.token, isNull);
      expect(auth.error, isNotNull);
      expect(await store.read(), isNull);
    });

    test('an AuthErrorLink stays signedOut', () async {
      final auth = build();
      await auth.ready;

      await auth.handleLink(const AuthErrorLink());

      expect(auth.state, AuthState.signedOut);
      expect(auth.error, isNotNull);
    });

    test(
        'a network failure during exchange stays signedOut, surfaces a '
        'retryable message, and clears nothing', () async {
      final client = MockClient((request) async {
        throw const SocketExceptionStub();
      });
      final auth = build(httpClient: client);
      await auth.ready;

      await auth.handleLink(const AuthCodeLink('the-code'));

      expect(auth.state, AuthState.signedOut);
      expect(auth.token, isNull);
      expect(auth.error, isNotNull);
      expect(await store.read(), isNull);
    });

    test('a fresh attempt clears a previous error', () async {
      final failing = MockClient((request) async => http.Response('', 401));
      final auth = build(httpClient: failing);
      await auth.ready;
      await auth.handleLink(const AuthCodeLink('bad'));
      expect(auth.error, isNotNull);

      await auth.signIn();

      expect(auth.error, isNull);
    });

    test('signOut clears the stored token and returns to signedOut',
        () async {
      await store.write('stored-token');
      final auth = build();
      await auth.ready;
      expect(auth.state, AuthState.signedIn);

      await auth.signOut();

      expect(auth.state, AuthState.signedOut);
      expect(auth.token, isNull);
      expect(await store.read(), isNull);
    });

    test('a ConnectorsResultLink is not this controller\'s business',
        () async {
      final auth = build();
      await auth.ready;

      // Must not throw, and must not change sign-in state.
      await auth.handleLink(const ConnectorsResultLink(ConnectorsOauthResult.ok));

      expect(auth.state, AuthState.signedOut);
    });
  });
}

/// A minimal stand-in for the kind of error a real `http.Client` throws when
/// the socket never connects (DNS failure, refused connection, no network) —
/// [AuthController] must not care about ITS type, only that the request
/// threw rather than returned.
class SocketExceptionStub implements Exception {
  const SocketExceptionStub();
}
