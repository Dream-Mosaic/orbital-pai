import 'package:flutter/material.dart';
import 'app_version.dart';
import 'meridian/nav.dart';
import 'meridian/panel_webview.dart';
import 'meridian/tokens.dart';
import 'meridian/voice_screen.dart';
import 'spike/porcupine_spike_screen.dart';
import 'voice/voice_controller.dart';
import 'web_url.dart';

void main() => runApp(const HenryApp());

class HenryApp extends StatelessWidget {
  const HenryApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Henry',
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(useMaterial3: true).copyWith(
          scaffoldBackgroundColor: M.bg,
        ),
        home: const HenryHome(),
      );
}

class HenryHome extends StatefulWidget {
  const HenryHome({super.key});

  @override
  State<HenryHome> createState() => _HenryHomeState();
}

class _HenryHomeState extends State<HenryHome> {
  final VoiceController _vc = VoiceController();

  @override
  void initState() {
    super.initState();
    // No manual Connect button any more — the controller owns connect + rejoin.
    _vc.connect();
  }

  @override
  void dispose() {
    _vc.dispose();
    super.dispose();
  }

  /// Opening a panel is now a plain push: `/?panel=<name>` renders the drawer
  /// with no voice shell, so the webview never joins the channel and the
  /// conversation keeps running underneath — mic, orb and thread all untouched.
  void _openPanel(MeridianTab tab) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => PanelWebViewScreen(tab: tab, url: kPanelUrl(tab)),
    ));
  }

  /// PorcupineSpikeScreen lost its home when the debug AppBar was deleted; it is
  /// the harness for the deferred wake-word + AEC work, so it lives on here.
  void _openSpike() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => const PorcupineSpikeScreen(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return MeridianVoiceScreen(
      controller: _vc,
      userName: 'David',
      appVersion: kAppVersion,
      onOpenPanel: _openPanel,
      onDevEntry: _openSpike,
    );
  }
}
