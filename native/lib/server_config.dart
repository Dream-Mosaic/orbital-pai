/// The one place the server address is decided. `--dart-define` so a release build reaches
/// production without editing a gitignored file, and a dev build still points at the laptop.
const String kServerHost =
    String.fromEnvironment('SERVER_HOST', defaultValue: 'ai.clausens.cloud');
const int kServerPort = int.fromEnvironment('SERVER_PORT', defaultValue: 443);

/// TLS is inferred from the port rather than configured separately: two knobs that must agree
/// are one knob too many, and the failure (ws:// to a wss:// endpoint) is a silent hang.
bool get kServerSecure => kServerPort == 443;

String get kHttpBase =>
    '${kServerSecure ? "https" : "http"}://$kServerHost:$kServerPort';

String kSocketUrl(String token) =>
    '${kServerSecure ? "wss" : "ws"}://$kServerHost:$kServerPort'
    '/socket/websocket?vsn=2.0.0&token=$token';
