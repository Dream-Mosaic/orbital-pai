import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../deep_link.dart';
import '../server_config.dart';
import 'token_store.dart';

/// Where the app's sign-in state machine currently is.
///
/// [unknown] is the brief instant between construction and the first read of
/// the token store settling — the UI shows a blank/splash for it, never a
/// flash of the login screen it might immediately replace.
enum AuthState { unknown, signedOut, signedIn }

/// The sign-in state machine: reads the stored token at startup, opens the
/// Authentik flow in the system browser (`GET /auth/login?return=app`), and
/// exchanges the one-time code the server deep-links back
/// (`orbital://auth?code=…`) for a real socket token
/// (`POST /api/auth/exchange`).
///
/// Injectable [httpClient] and [store] so this is testable headless — no
/// platform channel, no real network call. See
/// test/auth/auth_controller_test.dart. `signIn()` itself calls
/// `package:url_launcher`'s top-level `launchUrl` directly rather than through
/// an injected seam, matching how `connectors_panel.dart` does the same thing
/// — a test registers a [FakeUrlLauncher] as the platform instance instead.
class AuthController extends ChangeNotifier {
  AuthController({required TokenStore store, http.Client? httpClient})
      : _store = store,
        _http = httpClient ?? http.Client() {
    _ready = _init();
  }

  final TokenStore _store;
  final http.Client _http;
  late final Future<void> _ready;

  AuthState _state = AuthState.unknown;
  String? _token;
  String? _error;

  AuthState get state => _state;

  /// The signed-in socket token, or null when not signed in. This is what
  /// `AppConnection` dials with — see main.dart, which never constructs a
  /// connection before this is non-null.
  String? get token => _token;

  /// A human-readable line describing the last failed attempt, or null.
  /// Cleared at the start of every new attempt so a stale failure never
  /// lingers on screen past a fresh success.
  String? get error => _error;

  /// Resolves once the initial store read has settled [state] to
  /// [AuthState.signedOut] or [AuthState.signedIn]. Tests await this instead
  /// of pumping an arbitrary number of microtasks.
  @visibleForTesting
  Future<void> get ready => _ready;

  Future<void> _init() async {
    final stored = await _store.read();
    _token = stored;
    _state = stored == null ? AuthState.signedOut : AuthState.signedIn;
    notifyListeners();
  }

  /// Opens the Authentik sign-in flow in the system browser.
  ///
  /// EXTERNAL, not an in-app webview: Authentik (like Google) refuses to
  /// authenticate inside one, and `connectors_panel.dart` already made this
  /// exact call for the exact same reason — see its `_launchIfNeeded`.
  Future<void> signIn() async {
    _error = null;
    notifyListeners();
    await launchUrl(
      Uri.parse('$kHttpBase/auth/login?return=app'),
      mode: LaunchMode.externalApplication,
    );
  }

  /// The deep link the browser hands back after the flow finishes.
  ///
  /// Only [AuthCodeLink] and [AuthErrorLink] are this controller's business —
  /// main.dart routes [ConnectorsResultLink] to the connectors panel instead —
  /// but [AppLink] is a sealed union, so every case has to be named here for
  /// the switch to be exhaustive.
  Future<void> handleLink(AppLink link) async {
    switch (link) {
      case AuthCodeLink(:final code):
        await _exchange(code);
      case AuthErrorLink():
        _error = "Sign-in didn't complete. Try again.";
        _state = AuthState.signedOut;
        notifyListeners();
      case ConnectorsResultLink():
        break;
    }
  }

  Future<void> _exchange(String code) async {
    try {
      final resp = await _http.post(
        Uri.parse('$kHttpBase/api/auth/exchange'),
        headers: const {'content-type': 'application/json'},
        body: jsonEncode({'code': code}),
      );
      if (resp.statusCode == 200) {
        final token =
            (jsonDecode(resp.body) as Map<String, dynamic>)['token'] as String;
        await _store.write(token);
        _token = token;
        _error = null;
        _state = AuthState.signedIn;
      } else {
        // 401 invalid_code — expired, already used, or never minted; the
        // server deliberately makes those indistinguishable. Nothing was
        // written, so there is nothing to roll back.
        _error = 'That sign-in link has expired. Try again.';
        _state = AuthState.signedOut;
      }
    } catch (_) {
      // The exchange never reached the server, or never came back. This is
      // NOT a rejection — it must not be treated like one. Surface something
      // retryable and change nothing else: no token was written, and this
      // path only ever runs from signedOut, so there is nothing stored to
      // clear.
      _error = 'Could not reach the server. Check your connection and try again.';
      _state = AuthState.signedOut;
    }
    notifyListeners();
  }

  /// Forgets the stored token and returns to signedOut.
  ///
  /// Called from two places: a future Settings entry point, and
  /// [handleSocketRejected] below.
  Future<void> signOut() async {
    await _store.clear();
    _token = null;
    _error = null;
    _state = AuthState.signedOut;
    notifyListeners();
  }

  /// Adapts this controller to `AppConnection.onRejected`
  /// (`connection/app_connection.dart`): the socket reported that the server
  /// refused it outright — a dead token — so forget it and drop back to
  /// signedOut. Reuses [signOut] rather than duplicating its clear-and-reset.
  ///
  /// This is the REJECTED half of a deliberate asymmetry: an unreachable
  /// server must never reach here, and `AppConnection` only calls this
  /// hook for an actual refusal — see its `_isRejection` — never for a
  /// connection that simply could not be established. Getting that backwards
  /// would sign the user out every time their wifi dropped.
  Future<void> handleSocketRejected() => signOut();

  @override
  void dispose() {
    _http.close();
    super.dispose();
  }
}
