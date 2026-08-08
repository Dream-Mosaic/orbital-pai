import 'package:flutter/foundation.dart' show LicenseEntryWithLineBreaks, LicenseRegistry;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'app_version.dart';
import 'connection/app_connection.dart';
import 'meridian/nav.dart';
import 'meridian/panel_webview.dart';
import 'meridian/tokens.dart';
import 'meridian/voice_screen.dart';
import 'spike/porcupine_spike_screen.dart';
import 'voice/voice_controller.dart';
import 'web_url.dart';

void main() {
  // The bundled Space Grotesk / Inter are SIL OFL; surface their attribution in
  // the standard licence page rather than burying it in the asset folder.
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(
      const ['Space Grotesk', 'Inter'],
      await rootBundle.loadString('assets/fonts/ATTRIBUTION.txt'),
    );
  });
  runApp(const HenryApp());
}

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
  final AppConnection _conn = AppConnection();

  // Assigned in initState(), NOT via `late final ... = VoiceController(...)`:
  // that lazy form would defer construction to build()'s first read, which
  // runs AFTER connect() below — so the controller would adopt an
  // already-joined connection instead of joining alongside it.
  late final VoiceController _vc;

  @override
  void initState() {
    super.initState();
    _vc = VoiceController(connection: _conn);
    // The connection owns connect + rejoin; consumers just open channels.
    _conn.connect();
  }

  @override
  void dispose() {
    _vc.dispose();
    _conn.dispose();
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
      connection: _conn,
      userName: 'David',
      appVersion: kAppVersion,
      onOpenPanel: _openPanel,
      onDevEntry: _openSpike,
    );
  }
}
