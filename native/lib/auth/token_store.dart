import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The one thing worth persisting across launches: the socket token proving
/// this device is a signed-in user. Backed by the platform keystore
/// (Keychain / Keystore / DPAPI …) rather than shared prefs, since it is a
/// live credential, not a UI preference.
///
/// A single key, injectable storage for tests. There is exactly one token —
/// this app has no concept of multiple accounts — so there is no id
/// parameter to get wrong.
class TokenStore {
  TokenStore({FlutterSecureStorage? storage})
      : _s = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _s;

  static const _key = 'socket_token';

  /// The stored token, or null if there is none — or if the platform
  /// keystore itself is unavailable.
  ///
  /// That second case is deliberate: a device whose keystore cannot be
  /// reached (a corrupted keystore, a locked profile, some OEM lockdown) must
  /// degrade to "signed out" so the app can still show its login screen,
  /// never crash on launch because reading a credential threw.
  Future<String?> read() async {
    try {
      return await _s.read(key: _key);
    } catch (_) {
      return null;
    }
  }

  Future<void> write(String token) => _s.write(key: _key, value: token);

  Future<void> clear() => _s.delete(key: _key);
}
