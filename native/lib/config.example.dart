// Copy to `config.dart` (gitignored) and fill in real values.
// TOKEN: from the running web app's page, element with `data-user-token`
//   (rendered by conversation_live.ex). Valid ~30 days.
// HOST: the Mac's LAN IP running the Phoenix dev server on PORT 8787.
const String kSocketToken = 'PASTE_30_DAY_SOCKET_TOKEN_HERE';
const String kServerHost = '192.168.1.XXX';
const int kServerPort = 8787;
const String kPicovoiceAccessKey = 'PASTE_PICOVOICE_ACCESS_KEY_HERE';

String kSocketUrl(String token) =>
    'ws://$kServerHost:$kServerPort/socket/websocket?vsn=2.0.0&token=$token';
