import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

/// One recorded call to [FakeUrlLauncher.launchUrl] — the url and the mode it
/// was asked to launch with, so a test can tell "launched the right thing"
/// from "launched something".
class LaunchedUrl {
  const LaunchedUrl(this.url, this.mode);

  final String url;
  final PreferredLaunchMode mode;
}

/// The smallest `UrlLauncherPlatform` that makes launching a POSITIVE,
/// OBSERVABLE outcome.
///
/// This mirrors the lesson `fake_webview_platform.dart` banked and this
/// project then deleted (`chore(native): retire the panel WebView`,
/// 2026-08-26): a bare `expect(find.byType(PanelWebViewScreen), findsNothing)`
/// against a platform interface that was never registered is a TAUTOLOGY.
/// With no `WebViewPlatform.instance` set, `WebViewController()` throws
/// inside `initState`, the screen can never mount, and "not found" says
/// nothing about routing — it was true for two review phases regardless of
/// whether the routing logic was right.
///
/// `url_launcher` has the identical trap: with no `UrlLauncherPlatform.
/// instance` registered, `launchUrl()`/`launch()` throw `UnimplementedError`
/// before doing anything, so "an error reply launches nothing" would pass
/// whether or not the panel would ever have launched a URL at all. Registering
/// THIS platform closes that gap: [launches] is a real, growing list — a
/// launch is something that provably CAN happen (and is recorded when it
/// does), so a test asserting it did NOT happen is asserting something that
/// could have gone the other way.
///
/// Only the modern [launchUrl] entry point is implemented — the one
/// `package:url_launcher`'s own `launchUrl(Uri, {mode})` calls
/// (`url_launcher_uri.dart`) — because that is the only entry point this
/// codebase's panel uses. `canLaunch` is not overridden: nothing here calls
/// `canLaunchUrl` first, and stubbing a call nobody makes would just be dead
/// weight that could silently start passing if that ever changed unnoticed.
class FakeUrlLauncher extends UrlLauncherPlatform {
  final List<LaunchedUrl> launches = <LaunchedUrl>[];

  /// Install this fake as [UrlLauncherPlatform.instance] and hand back the
  /// same instance so a test can read [launches] off it. The platform
  /// interface's setter has no "unregister" — tests that want a clean slate
  /// between cases should register a FRESH [FakeUrlLauncher] (or clear
  /// [launches]) rather than rely on any reset.
  static FakeUrlLauncher register() {
    final fake = FakeUrlLauncher();
    UrlLauncherPlatform.instance = fake;
    return fake;
  }

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launches.add(LaunchedUrl(url, options.mode));
    return true;
  }
}
