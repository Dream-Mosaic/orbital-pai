/// Deep links the system browser hands back to this app.
///
/// These are NOT OAuth redirect URIs. By the time one arrives the OAuth flow is already
/// finished server-side — the code was exchanged and the account stored — and the link's only
/// job is to bring the app forward and say how it went. Google never sees these, which is why
/// adding a connector needs no Google Cloud change. See `AppWeb.AppLink` on the server.
///
/// ## Everything here is untrusted
///
/// An `intent-filter` is open to every app on the device, not just to our own server: anything
/// installed here can fire `henry://connectors?status=...` at us whenever it likes. So
/// [parseConnectorsLink] is written as an allowlist that returns null for anything it does not
/// positively recognize, and the server deliberately sends a bounded status rather than a
/// human-readable message — a free-text field would hand any installed app the ability to write
/// whatever it wanted into a banner inside Henry.
///
/// Nothing is lost by that: the panel refetches on resume, so the account list already shows
/// the specifics. The status only decides which of two sentences to show while that lands.
library;

/// The custom scheme, matching `android:scheme` in
/// android/app/src/main/AndroidManifest.xml and `@scheme` in server/lib/app_web/app_link.ex.
/// Chosen to match the applicationId (com.henry.henry_wall).
///
/// Changing it means changing all three AND reinstalling the app — Android reads the
/// intent-filter at install time, so a rebuild alone will not re-register a new scheme.
const String kAppScheme = 'henry';

/// How a connector flow that went out to the browser came back.
enum ConnectorsOauthResult {
  /// The grant (or reduction) completed. What actually changed is whatever the panel's
  /// refetch reports — this only says the flow reached the end.
  ok,

  /// It did not complete: cancelled at Google's consent screen, a failed token exchange, or a
  /// server-side refusal before the hop out. Nothing changed.
  failed,
}

/// The result carried by [uri], or null if this is not a link this app acts on.
///
/// Null for every unrecognized shape rather than a default: an unknown status is exactly the
/// case where guessing is worst — reading a malformed link as [ConnectorsOauthResult.ok] would
/// tell the user a connection succeeded on no evidence at all.
ConnectorsOauthResult? parseConnectorsLink(Uri uri) {
  if (uri.scheme != kAppScheme || uri.host != 'connectors') return null;
  return switch (uri.queryParameters['status']) {
    'ok' => ConnectorsOauthResult.ok,
    'error' => ConnectorsOauthResult.failed,
    _ => null,
  };
}
