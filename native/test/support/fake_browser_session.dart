import 'package:orbital_pai/auth/browser_session.dart';

/// A [BrowserSession] whose outcome is decided up front. [opened] records every
/// url handed to it, so a test can assert what was launched as well as what
/// came back — the same lesson fake_url_launcher.dart banked: "nothing was
/// launched" is only a result when launching provably could have happened.
///
/// [result] null models the user dismissing the sheet (the real session
/// resolves null for that); [error] models the platform refusing to open one.
class FakeBrowserSession implements BrowserSession {
  FakeBrowserSession({this.result, this.error});

  final Uri? result;
  final Object? error;
  final List<Uri> opened = <Uri>[];

  @override
  Future<Uri?> run(Uri url) {
    opened.add(url);
    final error = this.error;
    if (error != null) return Future<Uri?>.error(error);
    return Future<Uri?>.value(result);
  }
}
