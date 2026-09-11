/// The one place the server address is decided. `--dart-define` so a release build reaches
/// production without editing a gitignored file, and a dev build still points at the laptop.
const String kServerHost =
    String.fromEnvironment('SERVER_HOST', defaultValue: 'ai.clausens.cloud');
const int kServerPort = int.fromEnvironment('SERVER_PORT', defaultValue: 443);

/// TLS is inferred from the port rather than configured separately: two knobs that must agree
/// are one knob too many, and the failure (ws:// to a wss:// endpoint) is a silent hang.
///
/// Pulled out as a pure function of [port] — rather than inlined against [kServerPort] — so a
/// test can drive it at ports other than whatever this particular `flutter test` build's
/// `--dart-define`s happen to be. `kServerHost`/`kServerPort` are compile-time constants, so no
/// test process can ever observe [kServerSecure] disagree with them; a helper that takes the
/// port as an argument is the only way to put a mutation of the `== 443` under test.
bool secureForPort(int port) => port == 443;

bool get kServerSecure => secureForPort(kServerPort);

/// The scheme + host + port an HTTP request against [host]/[port] uses, agreeing with
/// [secureForPort]. See [secureForPort] for why this takes its inputs as parameters.
String httpBaseFor(String host, int port) =>
    '${secureForPort(port) ? "https" : "http"}://$host:$port';

String get kHttpBase => httpBaseFor(kServerHost, kServerPort);

/// The websocket URL for [host]/[port] carrying [token], agreeing with [secureForPort]. See
/// [secureForPort] for why this takes its inputs as parameters.
String socketUrlFor(String host, int port, String token) =>
    '${secureForPort(port) ? "wss" : "ws"}://$host:$port'
    '/socket/websocket?vsn=2.0.0&token=$token';

String kSocketUrl(String token) => socketUrlFor(kServerHost, kServerPort, token);
