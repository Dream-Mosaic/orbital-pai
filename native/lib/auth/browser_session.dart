import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';

import '../deep_link.dart';

/// A browser round-trip that comes back on its own.
///
/// Opens [url] in the OS auth session — an Android Custom Tab today,
/// `ASWebAuthenticationSession` on Apple platforms once those runners exist —
/// and resolves with the `orbital://` URL the server redirects to at the end.
/// The session dismisses itself when that URL fires, which is the whole point:
/// `url_launcher` + an intent-filter left the tab behind.
///
/// Resolves null when the user dismissed the sheet. Anything the callback
/// carries is still untrusted on arrival (see deep_link.dart): callers run it
/// through [parseAppLink], never read it raw.
abstract class BrowserSession {
  Future<Uri?> run(Uri url);
}

/// The production session, over `flutter_web_auth_2`.
///
/// The Custom Tab shares the system browser's cookies (no `preferEphemeral`),
/// so the Authentik session survives between sign-ins. [kAppScheme] is what
/// the package's `CallbackActivity` is registered for in AndroidManifest.xml.
class WebAuthBrowserSession implements BrowserSession {
  const WebAuthBrowserSession();

  @override
  Future<Uri?> run(Uri url) async {
    try {
      final result = await FlutterWebAuth2.authenticate(
        url: url.toString(),
        callbackUrlScheme: kAppScheme,
      );
      return Uri.parse(result);
    } on PlatformException catch (e) {
      // The package's own code for "the user closed the sheet". Not a failure
      // — nothing happened, and the caller decides whether that needs saying.
      if (e.code == 'CANCELED') return null;
      rethrow;
    }
  }
}
