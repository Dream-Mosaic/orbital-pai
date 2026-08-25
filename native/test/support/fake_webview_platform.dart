import 'package:flutter/widgets.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

/// The smallest `WebViewPlatform` that lets [PanelWebViewScreen] actually
/// MOUNT in a widget test.
///
/// Register it whenever a test asserts about the webview station — including
/// the tests that assert a station is NOT the webview. Without it,
/// `WebViewController()` asserts inside `initState`, the framework swaps the
/// whole screen for an ErrorWidget, and `find.byType(PanelWebViewScreen)`
/// finds NOTHING. That would make every `expect(find.byType(
/// PanelWebViewScreen), findsNothing)` pass for the wrong reason: a station
/// that had wrongly fallen through to the webview would still "find nothing".
/// With this registered, "webview" is a positive, findable outcome, so webview
/// and not-webview are genuinely distinguishable.
class FakeWebViewPlatform extends WebViewPlatform {
  /// Idempotent: [WebViewPlatform.instance]'s setter rejects null, so there is
  /// no un-registering it, and a second test in the same file must not install
  /// a second instance.
  static void register() {
    if (WebViewPlatform.instance is! FakeWebViewPlatform) {
      WebViewPlatform.instance = FakeWebViewPlatform();
    }
  }

  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) =>
      _FakeWebViewController(params);

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) =>
      _FakeWebViewWidget(params);
}

/// Only the three calls `PanelWebViewScreen.initState` makes are overridden;
/// everything else stays `UnimplementedError`, so a screen that starts driving
/// the webview harder fails loudly rather than silently doing nothing.
class _FakeWebViewController extends PlatformWebViewController {
  _FakeWebViewController(super.params) : super.implementation();

  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async {}

  @override
  Future<void> setBackgroundColor(Color color) async {}

  @override
  Future<void> loadRequest(LoadRequestParams params) async {}
}

class _FakeWebViewWidget extends PlatformWebViewWidget {
  _FakeWebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}
