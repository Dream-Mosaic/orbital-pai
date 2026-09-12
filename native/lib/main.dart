import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart' show LicenseEntryWithLineBreaks, LicenseRegistry;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'app_version.dart';
import 'auth/auth_controller.dart';
import 'auth/token_store.dart';
import 'connection/app_connection.dart';
import 'deep_link.dart';
import 'meridian/books_panel.dart';
import 'meridian/connectors_panel.dart';
import 'meridian/drawer.dart';
import 'meridian/login_screen.dart';
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
  const HenryHome({
    super.key,
    this.connection,
    this.deepLinks,
    this.auth,
    this.buildConnection,
  });

  /// The one connection, injectable so a test can build the REAL home — and
  /// therefore the real `_openPanel` wiring below — against a fake socket.
  ///
  /// Supplying this BYPASSES sign-in entirely and goes straight to the
  /// connected shell, exactly as if [auth] were already [AuthState.signedIn]
  /// — this is what every drawer/routing test in this repo wants, and what
  /// keeps them from needing a real [AuthController] behind a fake token
  /// store just to reach the screen they are actually testing. Null
  /// (production) means: build the real [AuthController], show
  /// [LoginScreen] until it settles to signedIn, and only then dial the
  /// configured server. Whatever ends up here (or gets built once signed in)
  /// is owned by this widget and disposed with it.
  final AppConnection? connection;

  /// Deep links the OS delivers to this app — in practice the return hop from
  /// a connector OAuth flow, or an Authentik login, that finished in the
  /// system browser (see lib/deep_link.dart). Null means "no link source",
  /// which is what widget tests want and what makes the plugin's absence a
  /// non-event rather than a MissingPluginException.
  final Stream<Uri>? deepLinks;

  /// The sign-in state machine. Ignored entirely when [connection] is
  /// supplied (see above). Null (production, no injected connection)
  /// constructs a real one over the platform secure-storage-backed
  /// [TokenStore]. Injectable so a test can drive login -> LoginScreen ->
  /// signed-in without a platform channel behind it.
  final AuthController? auth;

  /// How to turn a freshly-signed-in token into the one real [AppConnection]
  /// this widget builds. Defaults to dialing the configured server. Tests
  /// that exercise the sign-in -> connected handoff override this to hand
  /// back an [AppConnection] wired to a fake socket instead — see
  /// `main_routing_test.dart`'s "deep links back from the browser" ->
  /// sign-in group.
  /// Injected connection factory. It takes `onRejected` as a PARAMETER rather than letting the
  /// default supply it privately, because the seam must not hide the wiring it stands in for:
  /// when this took only a token, `main.dart` forgot to pass `onRejected` at all and every test
  /// still passed — the rejected-token classifier was correct and completely inert in production.
  final AppConnection Function(String token, Future<void> Function()? onRejected)?
      buildConnection;

  @override
  State<HenryHome> createState() => _HenryHomeState();
}

class _HenryHomeState extends State<HenryHome> {
  /// Non-null only once [connection] was supplied directly, or [_auth]
  /// settled to [AuthState.signedIn] and [_buildShell] ran. Everything below
  /// it is built alongside it, in the same call, and nulled together with it
  /// — there is no state where one of these is set and another is not.
  AppConnection? _conn;
  VoiceController? _vc;
  BadgesClient? _badges;
  RemindersClient? _reminders;
  SettingsClient? _settings;
  MemoryClient? _memory;
  VoiceLockClient? _voiceLock;
  ConnectorsClient? _connectors;
  BooksClient? _books;

  /// Null exactly when [widget.connection] was supplied directly — that path
  /// (every drawer/routing test) has no sign-in state machine to speak of.
  AuthController? _auth;

  /// Whether THIS state built [_auth] and therefore owns disposing it.
  /// Distinct from `widget.auth == null`: a widget rebuild could hand this
  /// state a *different* injected controller later, which must never
  /// dispose a controller the caller still owns.
  bool _ownsAuth = false;

  StreamSubscription<Uri>? _linkSub;

  @override
  void initState() {
    super.initState();
    _linkSub = widget.deepLinks?.listen(_onDeepLink);

    final injected = widget.connection;
    if (injected != null) {
      _buildShell(injected);
      return;
    }

    final auth = widget.auth ?? AuthController(store: TokenStore());
    _ownsAuth = widget.auth == null;
    _auth = auth;
    auth.addListener(_onAuthChanged);
    if (auth.state == AuthState.signedIn) {
      // A store read that had already settled before this widget even
      // mounted (e.g. a hot restart) — build the shell immediately rather
      // than waiting on a notifyListeners() that already fired.
      _buildShell(_connectionFor(auth.token));
    }
  }

  /// The `onRejected` wiring is what makes Task 4's classifier reach production: without it
  /// `AppConnection` correctly identifies a refused token and then has nobody to tell, so the
  /// app retries forever exactly as it did before — the whole point of distinguishing a
  /// rejection from an outage, silently inert.
  AppConnection _connectionFor(String? token) =>
      (widget.buildConnection ??
          (t, onRejected) => AppConnection(token: t, onRejected: onRejected))(
        token ?? '',
        _auth?.handleSocketRejected,
      );

  void _onAuthChanged() {
    final auth = _auth;
    if (auth == null || !mounted) return;
    if (auth.state == AuthState.signedIn && _conn == null) {
      setState(() => _buildShell(_connectionFor(auth.token)));
    } else if (auth.state == AuthState.signedOut && _conn != null) {
      // The signedIn -> signedOut edge: a rejected token (AppConnection's
      // onRejected -> AuthController.signOut) or a future manual sign-out.
      // Without tearing the shell down, `build()` keeps returning
      // MeridianVoiceScreen forever — `_conn` is otherwise never reset to
      // null — so the user is left on a dead shell with no way back to
      // LoginScreen short of killing the app. See branch-review.md Critical 1.
      setState(_teardownShell);
    } else {
      setState(() {});
    }
  }

  /// Undoes [_buildShell]: disposes every client built alongside the
  /// connection, the connection itself, and the VoiceController, then nulls
  /// every field so [build] falls through to [LoginScreen]. Mirrors
  /// [dispose]'s disposal list exactly, minus `_auth` (which outlives the
  /// shell — a fresh sign-in reuses the same [AuthController]).
  void _teardownShell() {
    _books?.dispose();
    _connectors?.dispose();
    _voiceLock?.dispose();
    _memory?.dispose();
    _settings?.dispose();
    _reminders?.dispose();
    _badges?.dispose();
    _vc?.dispose();
    _conn?.dispose();
    _conn = null;
    _vc = null;
    _badges = null;
    _reminders = null;
    _settings = null;
    _memory = null;
    _voiceLock = null;
    _connectors = null;
    _books = null;
  }

  /// Wires the one connection to every client that rides on it, then tells
  /// the connection to dial. Called exactly once per [AppConnection] this
  /// widget ever owns — either immediately (an injected [connection], or an
  /// already-signed-in store on the first frame) or the moment [_auth]
  /// settles to signedIn.
  void _buildShell(AppConnection conn) {
    _conn = conn;
    // NOT `late final ... = VoiceController(...)`: that lazy form would defer
    // construction to build()'s first read, which runs AFTER connect() below
    // — so the controller would adopt an already-joined connection instead of
    // joining alongside it.
    final vc = VoiceController(connection: conn);
    _vc = vc;
    // Registered before connect() so the first sweep opens the badges topic
    // alongside the conversation, rather than as a second round trip.
    _badges = BadgesClient(connection: conn);
    // Registers nothing until the drawer opens.
    _reminders = RemindersClient(connection: conn);
    _settings = SettingsClient(
      connection: conn,
      // The web pushes "clear_log" to wipe the browser's transcript; this is
      // the same thing for the native thread.
      onLocalClear: vc.clearThread,
    );
    // Registers nothing until the drawer's Memory layer opens.
    _memory = MemoryClient(
      connection: conn,
      onLocalClear: vc.clearThread,
    );
    // Registers nothing until the drawer's Voice Lock layer opens. The mic
    // callbacks are the whole reason this client is constructed here: the
    // conversation owns the one microphone, and enrollment borrows it.
    _voiceLock = VoiceLockClient(
      connection: conn,
      acquireMic: vc.suspendMic,
      releaseMic: vc.resumeMic,
    );
    // Registers nothing until the Connectors drawer opens.
    _connectors = ConnectorsClient(connection: conn);
    // Registers nothing until the Books drawer opens.
    _books = BooksClient(connection: conn);
    // The connection owns connect + rejoin; consumers just open channels.
    conn.connect();
  }

  @override
  void dispose() {
    unawaited(_linkSub?.cancel());
    _teardownShell();
    if (_ownsAuth) {
      _auth?.dispose();
    } else {
      _auth?.removeListener(_onAuthChanged);
    }
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
  ///
  /// [AuthCodeLink] and [AuthErrorLink] are the return hop from a sign-in
  /// that finished in the system browser, and are [_auth]'s business, not
  /// this panel-opening logic's — `_auth` is null exactly when there is no
  /// sign-in state machine to hand them to (an injected [widget.connection]),
  /// in which case there is nothing to do with them.
  void _onDeepLink(Uri uri) {
    final link = parseAppLink(uri);
    // Null is every link this app does not positively recognize — including
    // anything another app on the device fired at our scheme. Ignored, never
    // guessed at. See parseAppLink.
    if (link == null || !mounted) return;
    switch (link) {
      case ConnectorsResultLink(:final result):
        final connectors = _connectors;
        if (connectors == null) return; // no shell yet — nothing to open
        if (!connectors.isOpen) _openPanel(MeridianTab.connectors);
        connectors.noteOauthResult(result);
      case AuthCodeLink():
      case AuthErrorLink():
        unawaited(_auth?.handleLink(link));
    }
  }

  /// Every station is native. A `switch` over the enum, with no default arm,
  /// so a sixth station is a compile error here rather than a silent
  /// fallthrough to a screen that no longer exists. The drawer is a
  /// transparent route, so the conversation keeps running and rendering
  /// behind the scrim — mic, orb and thread all untouched.
  ///
  /// Only ever called once the shell is built (see [build] — [onOpenPanel]
  /// is wired to [MeridianVoiceScreen], which only exists then), so the `!`s
  /// below are safe.
  void _openPanel(MeridianTab tab) {
    final reminders = _reminders!;
    final connectors = _connectors!;
    final settings = _settings!;
    final memory = _memory!;
    final voiceLock = _voiceLock!;
    final books = _books!;
    switch (tab) {
      case MeridianTab.reminders:
        reminders.open();
        Navigator.of(context)
            .push(meridianDrawerRoute(
              title: tab.label,
              child: RemindersPanelView(client: reminders),
            ))
            // whenComplete, not a then: a back gesture, a scrim tap and the ✕
            // all have to leave the topic, or the server keeps pushing state
            // at a panel nobody is looking at.
            .whenComplete(reminders.close);

      case MeridianTab.connectors:
        connectors.open();
        Navigator.of(context)
            .push(meridianDrawerRoute(
              title: tab.label,
              child: ConnectorsPanelView(client: connectors),
            ))
            // whenComplete, not a then: a back gesture, a scrim tap and the ✕
            // all have to leave the topic, or the server keeps pushing state
            // at a panel nobody is looking at.
            .whenComplete(connectors.close);

      case MeridianTab.settings:
        settings.open();
        Navigator.of(context)
            .push(meridianHostedDrawerRoute(
              builder: (context, animation, onClose) => SettingsDrawerHost(
                animation: animation,
                onClose: onClose,
                settings: settings,
                memory: memory,
                voiceLock: voiceLock,
              ),
            ))
            // The drawer can be dismissed from ANY layer (✕, scrim, or back),
            // so all three clients have to close here rather than each owning
            // its own whenComplete — whichever ones were NOT visible at
            // dismissal time are still open and would otherwise leak their
            // topic.
            .whenComplete(() {
          voiceLock.close();
          memory.close();
          settings.close();
        });

      case MeridianTab.search:
        // No channel: nothing to open or close.
        Navigator.of(context).push(meridianDrawerRoute(
          title: tab.label,
          child: const SearchPanelView(),
        ));

      case MeridianTab.books:
        books.open();
        Navigator.of(context)
            .push(meridianDrawerRoute(
              title: tab.label,
              child: BooksPanelView(client: books),
            ))
            // whenComplete, not a then: a back gesture, a scrim tap and the ✕
            // all have to leave the topic, or the server keeps pushing state
            // at a panel nobody is looking at.
            .whenComplete(books.close);
    }
  }

  @override
  Widget build(BuildContext context) {
    final conn = _conn;
    if (conn == null) {
      final auth = _auth;
      // signedOut (never unknown — [_onAuthChanged] only rebuilds after the
      // store read settles one way or the other) is the one case with
      // somewhere to send the user; anything else (unknown, or the one frame
      // between signedIn firing and _buildShell finishing) is a blank beat,
      // not a flash of the wrong screen.
      if (auth != null && auth.state == AuthState.signedOut) {
        return LoginScreen(controller: auth);
      }
      return const ColoredBox(color: M.bg);
    }
    return MeridianVoiceScreen(
      controller: _vc!,
      connection: conn,
      badges: _badges,
      userName: 'David',
      appVersion: kAppVersion,
      onOpenPanel: _openPanel,
    );
  }
}
