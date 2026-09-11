/// Deep links the system browser hands back to this app.
///
/// These are NOT OAuth redirect URIs. By the time one arrives the OAuth flow is already
/// finished server-side — the code was exchanged and the account stored (connectors) or the
/// login completed (auth) — and the link's only job is to bring the app forward and say how it
/// went. Google/Authentik never see these, which is why adding a connector needs no provider-side
/// change. See `AppWeb.AppLink` on the server.
///
/// ## Everything here is untrusted
///
/// An `intent-filter` is open to every app on the device, not just to our own server: anything
/// installed here can fire `orbital://connectors?status=...` or `orbital://auth?code=...` at us
/// whenever it likes. So [parseAppLink] is written as an allowlist that returns null for anything
/// it does not positively recognize, and the server deliberately sends only bounded/short values
/// rather than a human-readable message or an unbounded blob — a free-text field would hand any
/// installed app the ability to write whatever it wanted into a banner inside Henry, and an
/// unbounded `code` would let a hostile app push an arbitrarily large value into the HTTP body the
/// app later sends when exchanging it.
///
/// Nothing is lost by keeping the connectors status bounded: the panel refetches on resume, so the
/// account list already shows the specifics. The status only decides which of two sentences to
/// show while that lands.
library;

/// The custom scheme, matching `android:scheme` in
/// android/app/src/main/AndroidManifest.xml and `@scheme` in server/lib/app_web/app_link.ex.
/// Chosen to match the applicationId (com.orbital.pai).
///
/// Changing it means changing all three AND reinstalling the app — Android reads the
/// intent-filter at install time, so a rebuild alone will not re-register a new scheme.
const String kAppScheme = 'orbital';

/// A single-use login code cannot reasonably be longer than this. Capping it here — before it
/// ever reaches an [AuthCodeLink] — means a hostile app on the device cannot use our own scheme to
/// smuggle an arbitrarily large value into the HTTP body the app later sends when exchanging the
/// code for a token.
const int _maxAuthCodeLength = 512;

/// How a connector flow that went out to the browser came back.
enum ConnectorsOauthResult {
  /// The grant (or reduction) completed. What actually changed is whatever the panel's
  /// refetch reports — this only says the flow reached the end.
  ok,

  /// It did not complete: cancelled at Google's consent screen, a failed token exchange, or a
  /// server-side refusal before the hop out. Nothing changed.
  failed,
}

/// A deep link this app positively recognizes and acts on.
///
/// [parseAppLink] returns `null`, never an instance of this, for anything else — see the library
/// doc for why that matters. Sealed so a `switch` over the concrete subtypes is exhaustive: adding
/// a new link kind is a compile error everywhere the old ones were handled, not a silent
/// fallthrough.
sealed class AppLink {
  const AppLink();
}

/// The return hop from a connector OAuth flow that finished in the system browser.
class ConnectorsResultLink extends AppLink {
  const ConnectorsResultLink(this.result);

  final ConnectorsOauthResult result;
}

/// A single-use login code, minted by the server after an Authentik sign-in completes, waiting to
/// be exchanged over HTTP for a real token.
///
/// The token never travels in THIS deep link -- only this short-lived code does. That is not the
/// same as saying the token never appears in a URL at all: `server_config.dart`'s `kSocketUrl`
/// puts it in the websocket URL's query string (pre-existing, not introduced by this flow), so it
/// still reaches Cloudflare's access logs on every connect.
///
/// Single-use + a 60s TTL only defeats a LATER replay of a captured code (browser history, an
/// intent log, a nosy reader) -- it does nothing against INTERCEPTION, because the intent filter
/// (`orbital://auth`) is open to every app on the device, not just this one. Any app that also
/// declares the scheme can win Android's chooser and take the code first. The real mitigation for
/// that is PKCE, deliberately not implemented here: this is a two-user personal instance, so that
/// exposure is accepted rather than engineered against. See `AppWeb.AppLink.auth/1` on the server
/// for the matching note.
class AuthCodeLink extends AppLink {
  const AuthCodeLink(this.code);

  final String code;
}

/// The login flow did not complete (cancelled, or a server-side refusal before the redirect back).
/// Nothing was minted; there is no code to exchange.
class AuthErrorLink extends AppLink {
  const AuthErrorLink();
}

/// The link carried by [uri], or null if this is not a link this app acts on.
///
/// Null for every unrecognized shape rather than a default: an unknown status is exactly the case
/// where guessing is worst — reading a malformed link as [ConnectorsOauthResult.ok] would tell the
/// user a connection succeeded on no evidence at all, and building an [AuthCodeLink] out of a
/// missing, empty, or absurdly long `code` would hand a bogus (or hostile) value straight to the
/// token exchange. Every one of those shapes must come back null, never a partially-filled link.
AppLink? parseAppLink(Uri uri) {
  if (uri.scheme != kAppScheme) return null;
  switch (uri.host) {
    case 'connectors':
      return switch (uri.queryParameters['status']) {
        'ok' => const ConnectorsResultLink(ConnectorsOauthResult.ok),
        'error' => const ConnectorsResultLink(ConnectorsOauthResult.failed),
        _ => null,
      };
    case 'auth':
      if (uri.queryParameters['status'] == 'error') {
        return const AuthErrorLink();
      }
      final code = uri.queryParameters['code'];
      if (code == null || code.isEmpty || code.length > _maxAuthCodeLength) {
        return null;
      }
      return AuthCodeLink(code);
    default:
      return null;
  }
}
