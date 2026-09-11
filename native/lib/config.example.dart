// Copy to `config.dart` (gitignored) and fill in real values.
// TOKEN: from the running web app's page, element with `data-user-token`
//   (rendered by conversation_live.ex). Valid ~30 days. Only used until the
//   Authentik native login lands for good (see auth/auth_controller.dart) —
//   once you have signed in once, the app stores a real token itself.
// The server address (kServerHost/kServerPort) and kSocketUrl now live in
// server_config.dart, set via --dart-define — not this file.
const String kSocketToken = 'PASTE_30_DAY_SOCKET_TOKEN_HERE';
const String kPicovoiceAccessKey = 'PASTE_PICOVOICE_ACCESS_KEY_HERE';
