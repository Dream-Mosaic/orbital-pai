import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'nav.dart';
import 'tokens.dart';

/// A transitional panel: the existing web UI's drawer, in an in-app webview.
///
/// It loads `/?panel=<name>`, which renders that drawer WITHOUT the voice shell
/// — no `#voice`, no `phx-hook="Voice"`, so the page never joins
/// `voice:<session_id>`. That matters because VoiceChannel's
/// bind_session/set_client is last-client-wins: a webview that mounted the hook
/// would re-point the conversation's outbound stream at itself and cut the
/// native client out mid-turn. Nothing here needs to touch the mic or the socket.
///
/// One accepted, temporary clunk: a one-time Google login inside the webview (the
/// session cookie persists thereafter). Phases B–D delete this screen entirely.
class PanelWebViewScreen extends StatefulWidget {
  const PanelWebViewScreen({super.key, required this.tab, required this.url});

  final MeridianTab tab;
  final String url;

  @override
  State<PanelWebViewScreen> createState() => _PanelWebViewScreenState();
}

class _PanelWebViewScreenState extends State<PanelWebViewScreen> {
  late final WebViewController _controller;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted) // LiveView needs JS
      ..setBackgroundColor(M.bg)
      ..loadRequest(Uri.parse(widget.url));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: M.bg,
      appBar: AppBar(
        backgroundColor: M.bg,
        foregroundColor: M.ink,
        title: Text(widget.tab.label),
      ),
      body: WebViewWidget(controller: _controller),
    );
  }
}
