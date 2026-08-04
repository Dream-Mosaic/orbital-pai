import 'config.dart';
import 'meridian/nav.dart';

/// The web UI's base URL, derived from the EXISTING config.dart constants.
///
/// Deliberately NOT a new constant in config.example.dart: config.dart is
/// gitignored, so adding a required constant there would break every working
/// copy that already has one (the file would silently lack the new symbol and
/// `flutter analyze` would fail on a machine that never touched this plan).
String kWebBaseUrl() => 'http://$kServerHost:$kServerPort/';

/// The panel-only URL for [tab] (Task 8's server change): renders just that
/// drawer, with NO voice shell — so the page never mounts the web Voice hook and
/// therefore never joins the channel and never steals our conversation.
String kPanelUrl(MeridianTab tab) => '${kWebBaseUrl()}?panel=${tab.modal}';
