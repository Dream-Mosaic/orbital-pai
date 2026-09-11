// Copy to `config.dart` (gitignored) and fill in real values.
//
// There is no socket token here any more. The app signs in through Authentik
// like the web does: tap Sign in, authenticate in the browser, and the app
// stores a real token in platform secure storage (lib/auth/token_store.dart).
// Nothing to paste, nothing to expire in 30 days.
//
// The server address lives in server_config.dart, set via --dart-define
// (run-dev.sh points at the laptop; a release build defaults to production).
const String kPicovoiceAccessKey = 'PASTE_PICOVOICE_ACCESS_KEY_HERE';
