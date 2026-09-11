import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbital_pai/auth/token_store.dart';

/// A [FlutterSecureStoragePlatform] whose every method call throws, standing
/// in for a device whose keystore cannot be reached (locked profile,
/// corrupted keystore, OEM lockdown). [TokenStore.read] must degrade to
/// "signed out" against this rather than let the exception reach its caller
/// and crash the app on launch.
class _ThrowingSecureStoragePlatform extends FlutterSecureStoragePlatform {
  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) =>
      throw StateError('keystore unavailable');

  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) =>
      throw StateError('keystore unavailable');

  @override
  Future<void> delete({
    required String key,
    required Map<String, String> options,
  }) =>
      throw StateError('keystore unavailable');

  @override
  Future<bool> containsKey({
    required String key,
    required Map<String, String> options,
  }) =>
      throw StateError('keystore unavailable');

  @override
  Future<Map<String, String>> readAll({
    required Map<String, String> options,
  }) =>
      throw StateError('keystore unavailable');

  @override
  Future<void> deleteAll({required Map<String, String> options}) =>
      throw StateError('keystore unavailable');
}

void main() {
  group('TokenStore', () {
    late TestFlutterSecureStoragePlatform fakePlatform;
    late TokenStore store;

    setUp(() {
      fakePlatform = TestFlutterSecureStoragePlatform(<String, String>{});
      FlutterSecureStoragePlatform.instance = fakePlatform;
      store = TokenStore(storage: const FlutterSecureStorage());
    });

    test('read returns null when nothing has been written', () async {
      expect(await store.read(), isNull);
    });

    test('read returns what write stored', () async {
      await store.write('a-token');
      expect(await store.read(), 'a-token');
    });

    test('write overwrites a previously stored token', () async {
      await store.write('first');
      await store.write('second');
      expect(await store.read(), 'second');
    });

    test('clear removes the stored token', () async {
      await store.write('a-token');
      await store.clear();
      expect(await store.read(), isNull);
    });

    test('clear is safe to call with nothing stored', () async {
      await store.clear();
      expect(await store.read(), isNull);
    });

    test('a throwing keystore degrades read to null rather than throwing',
        () async {
      FlutterSecureStoragePlatform.instance = _ThrowingSecureStoragePlatform();
      final degraded = TokenStore(storage: const FlutterSecureStorage());

      expect(await degraded.read(), isNull);
    });
  });
}
