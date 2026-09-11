import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart' show LicenseEntryWithLineBreaks, LicenseRegistry;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'app_version.dart';
import 'connection/app_connection.dart';
import 'deep_link.dart';
import 'meridian/books_panel.dart';
import 'meridian/connectors_panel.dart';
import 'meridian/drawer.dart';
import 'meridian/nav.dart';
import 'meridian/reminders_panel.dart';
import 'meridian/search_panel.dart';
import 'meridian/settings_drawer_host.dart';
import 'meridian/tokens.dart';
import 'meridian/voice_screen.dart';
import 'panels/badges_client.dart';
import 'panels/books_client.dart';
import 'panels/connectors_client.dart';
import 'panels/memory_client.dart';
import 'panels/reminders_client.dart';
import 'panels/settings_client.dart';
import 'panels/voice_lock_client.dart';
import 'spike/porcupine_spike_screen.dart';
import 'voice/voice_controller.dart';

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
        // The plugin is constructed HERE, not inside HenryHome, so that
        // HenryHome stays buildable in a widget test without a platform
        // channel behind it — every test builds HenryHome directly and simply
        // passes no stream. See [HenryHome.deepLinks].
        home: HenryHome(deepLinks: AppLinks().uriLinkStream),
      );
}

class HenryHome extends StatefulWidget {
  const HenryHome({super.key, this.connection, this.deepLinks});

  /// The one connection, injectable so a test can build the REAL home — and
  /// therefore the real `_openPanel` wiring below — against a fake socket.
  /// Null (production) constructs one, which dials the configured server.
  /// Whatever ends up here is owned by this widget and disposed with it.
  final AppConnection? connection;

  /// Deep links the OS delivers to this app — in practice the return hop from
  /// a connector OAuth flow that finished in the system browser (see
  /// lib/deep_link.dart). Null means "no link source", which is what widget
  /// tests want and what makes the plugin's absence a non-event rather than a
  /// MissingPluginException.
  final Stream<Uri>? deepLinks;

  @override
  State<HenryHome> createState() => _HenryHomeState();
}

class _HenryHomeState extends State<HenryHome> {
  // Assigned in initState() rather than inline, because a field initializer
  // cannot read `widget`.
  late final AppConnection _conn;

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
  late final BooksClient _books;

  StreamSubscription<Uri>? _linkSub;

  @override
  void initState() {
    super.initState();
    _linkSub = widget.deepLinks?.listen(_onDeepLink);
    _conn = widget.connection ?? AppConnection();
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
    // Registers nothing until the Books drawer opens.
    _books = BooksClient(connection: _conn);
    // The connection owns connect + rejoin; consumers just open channels.
    _conn.connect();
  }

  @override
  void dispose() {
    unawaited(_linkSub?.cancel());
    _books.dispose();
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

  /// A connector flow that went out to the system browser has come back.
  ///
  /// Opening the panel when it is closed is the point, not a nicety: the user
  /// may well have shut the drawer — or the whole app — while they were away,
  /// and a result delivered to a panel nobody can see is a result nobody gets.
  /// [ConnectorsClient.isOpen] is the single source of truth for whether the
  /// drawer is up; there is no second flag here to drift from it, because
  /// `_openPanel` is the only thing that opens this client and the route's
  /// `whenComplete` is the only thing that closes it.
  ///
  /// Order matters: open first, then record. [ConnectorsClient.close] clears
  /// the result, so recording into a closed client and opening afterwards
  /// would show nothing at all.
  void _onDeepLink(Uri uri) {
    final link = parseAppLink(uri);
    // Null is every link this app does not positively recognize — including
    // anything another app on the device fired at our scheme. Ignored, never
    // guessed at. See parseAppLink.
    if (link == null || !mounted) return;
    switch (link) {
      case ConnectorsResultLink(:final result):
        if (!_connectors.isOpen) _openPanel(MeridianTab.connectors);
        _connectors.noteOauthResult(result);
      case AuthCodeLink():
      case AuthErrorLink():
        // The login flow itself is wired in a later task; for now these
        // links are recognized but intentionally left unhandled.
        break;
    }
  }

  /// Every station is native. A `switch` over the enum, with no default arm,
  /// so a sixth station is a compile error here rather than a silent
  /// fallthrough to a screen that no longer exists. The drawer is a
  /// transparent route, so the conversation keeps running and rendering
  /// behind the scrim — mic, orb and thread all untouched.
  void _openPanel(MeridianTab tab) {
    switch (tab) {
      case MeridianTab.reminders:
        _reminders.open();
        Navigator.of(context)
            .push(meridianDrawerRoute(
              title: tab.label,
              child: RemindersPanelView(client: _reminders),
            ))
            // whenComplete, not a then: a back gesture, a scrim tap and the ✕
            // all have to leave the topic, or the server keeps pushing state
            // at a panel nobody is looking at.
            .whenComplete(_reminders.close);

      case MeridianTab.connectors:
        _connectors.open();
        Navigator.of(context)
            .push(meridianDrawerRoute(
              title: tab.label,
              child: ConnectorsPanelView(client: _connectors),
            ))
            // whenComplete, not a then: a back gesture, a scrim tap and the ✕
            // all have to leave the topic, or the server keeps pushing state
            // at a panel nobody is looking at.
            .whenComplete(_connectors.close);

      case MeridianTab.settings:
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

      case MeridianTab.search:
        // No channel: nothing to open or close.
        Navigator.of(context).push(meridianDrawerRoute(
          title: tab.label,
          child: const SearchPanelView(),
        ));

      case MeridianTab.books:
        _books.open();
        Navigator.of(context)
            .push(meridianDrawerRoute(
              title: tab.label,
              child: BooksPanelView(client: _books),
            ))
            // whenComplete, not a then: a back gesture, a scrim tap and the ✕
            // all have to leave the topic, or the server keeps pushing state
            // at a panel nobody is looking at.
            .whenComplete(_books.close);
    }
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
