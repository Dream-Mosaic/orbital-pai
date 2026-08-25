import 'package:flutter/foundation.dart' show LicenseEntryWithLineBreaks, LicenseRegistry;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'app_version.dart';
import 'connection/app_connection.dart';
import 'meridian/connectors_panel.dart';
import 'meridian/drawer.dart';
import 'meridian/nav.dart';
import 'meridian/panel_webview.dart';
import 'meridian/reminders_panel.dart';
import 'meridian/search_panel.dart';
import 'meridian/settings_drawer_host.dart';
import 'meridian/tokens.dart';
import 'meridian/voice_screen.dart';
import 'panels/badges_client.dart';
import 'panels/connectors_client.dart';
import 'panels/memory_client.dart';
import 'panels/reminders_client.dart';
import 'panels/settings_client.dart';
import 'panels/voice_lock_client.dart';
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
  late final BadgesClient _badges;
  late final RemindersClient _reminders;
  late final SettingsClient _settings;
  late final MemoryClient _memory;
  late final VoiceLockClient _voiceLock;
  late final ConnectorsClient _connectors;

  @override
  void initState() {
    super.initState();
    _vc = VoiceController(connection: _conn);
    // Registered before connect() so the first sweep opens the badges topic
    // alongside the conversation, rather than as a second round trip.
    _badges = BadgesClient(connection: _conn);
    // Registers nothing until the drawer opens.
    _reminders = RemindersClient(connection: _conn);
    _settings = SettingsClient(
      connection: _conn,
      // The web pushes "clear_log" to wipe the browser's transcript; this is
      // the same thing for the native thread.
      onLocalClear: _vc.clearThread,
    );
    // Registers nothing until the drawer's Memory layer opens.
    _memory = MemoryClient(
      connection: _conn,
      onLocalClear: _vc.clearThread,
    );
    // Registers nothing until the drawer's Voice Lock layer opens. The mic
    // callbacks are the whole reason this client is constructed here: the
    // conversation owns the one microphone, and enrollment borrows it.
    _voiceLock = VoiceLockClient(
      connection: _conn,
      acquireMic: _vc.suspendMic,
      releaseMic: _vc.resumeMic,
    );
    // Registers nothing until the Connectors drawer opens.
    _connectors = ConnectorsClient(connection: _conn);
    // The connection owns connect + rejoin; consumers just open channels.
    _conn.connect();
  }

  @override
  void dispose() {
    _connectors.dispose();
    _voiceLock.dispose();
    _memory.dispose();
    _settings.dispose();
    _reminders.dispose();
    _badges.dispose();
    _vc.dispose();
    _conn.dispose();
    super.dispose();
  }

  /// Reminders, Settings, Connectors and Search are native now; Books still
  /// loads `/?panel=<name>` in a webview until its own spec retires it. The
  /// drawer is a transparent route, so the conversation keeps running and
  /// rendering behind the scrim — mic, orb and thread all untouched.
  void _openPanel(MeridianTab tab) {
    if (tab == MeridianTab.reminders) {
      _reminders.open();
      Navigator.of(context)
          .push(meridianDrawerRoute(
            title: tab.label,
            child: RemindersPanelView(client: _reminders),
          ))
          // whenComplete, not a then: a back gesture, a scrim tap and the ✕ all
          // have to leave the topic, or the server keeps pushing state at a
          // panel nobody is looking at.
          .whenComplete(_reminders.close);
      return;
    }

    if (tab == MeridianTab.connectors) {
      _connectors.open();
      Navigator.of(context)
          .push(meridianDrawerRoute(
            title: tab.label,
            child: ConnectorsPanelView(client: _connectors),
          ))
          // whenComplete, not a then: a back gesture, a scrim tap and the ✕ all
          // have to leave the topic, or the server keeps pushing state at a
          // panel nobody is looking at.
          .whenComplete(_connectors.close);
      return;
    }

    if (tab == MeridianTab.settings) {
      _settings.open();
      Navigator.of(context)
          .push(meridianHostedDrawerRoute(
            builder: (context, animation, onClose) => SettingsDrawerHost(
              animation: animation,
              onClose: onClose,
              settings: _settings,
              memory: _memory,
              voiceLock: _voiceLock,
            ),
          ))
          // The drawer can be dismissed from ANY layer (✕, scrim, or back),
          // so all three clients have to close here rather than each owning
          // its own whenComplete — whichever ones were NOT visible at
          // dismissal time are still open and would otherwise leak their
          // topic.
          .whenComplete(() {
        _voiceLock.close();
        _memory.close();
        _settings.close();
      });
      return;
    }

    if (tab == MeridianTab.search) {
      // No channel: nothing to open or close.
      Navigator.of(context).push(meridianDrawerRoute(
        title: tab.label,
        child: const SearchPanelView(),
      ));
      return;
    }

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
      badges: _badges,
      userName: 'David',
      appVersion: kAppVersion,
      onOpenPanel: _openPanel,
      onDevEntry: _openSpike,
    );
  }
}
