import 'dart:async';

import 'package:flutter/material.dart' hide FormField;
import 'package:url_launcher/url_launcher.dart';

import '../deep_link.dart';
import '../panels/connectors_client.dart';
import 'hero_icon.dart';
import 'tokens.dart';

/// The known field-renderer kinds, mapped from the server's free-form
/// [FormField.type] string.
///
/// This indirection exists ONLY so [_ConnectorsPanelViewState._field]'s
/// switch can be exhaustive: Dart cannot enforce exhaustiveness over an
/// arbitrary `String` (there is no way to "list all strings" the way there is
/// for an enum), but it CAN over an enum — so the actual rendering decision
/// switches on THIS, not the raw wire value. [unknown] is the deliberate
/// catch-all; note that this mapping classifies, it does not render — the
/// switch that renders still has to spell out what [unknown] draws, so a
/// field type nobody taught this client about is a visible failure rather
/// than a silently missing input.
enum _FieldKind { accountSelect, choice, unknown }

_FieldKind _kindOf(String type) => switch (type) {
      'account_select' => _FieldKind.accountSelect,
      'choice' => _FieldKind.choice,
      _ => _FieldKind.unknown,
    };

/// The web's `#voice-modal .btn-error { color: #f87171 }` red, the same
/// clipped-oklch conversion banked as settings_panel.dart's and
/// memory_panel.dart's own `_dangerRed` — duplicated here rather than shared
/// because it is `_`-private to each library.
const Color _dangerRed = Color(0xFFEA003E);

/// The Connectors drawer's contents — the port of `connectors_panel/1` in
/// `lib/app_web/components/voice_modals.ex` (~379-482): one row per
/// (account, connector) grant, each with its label, email, an optional
/// default badge/button pair, an access badge, and a Disconnect button,
/// followed by a `+ Connect account` button and, while open, the "Add a
/// connection" grant form.
///
/// Server-authoritative, same pattern as the other panels: every write
/// pushes and the UI re-renders from the next `state`. [Connection] arrives
/// already sorted `{label, email}` and this view must NOT re-sort it, and
/// `showsDefault`/`onlyGrant` arrive pre-derived — this view must not
/// re-derive either.
///
/// **Both flows that used to be dead ends are now real actions**, per
/// `docs/superpowers/specs/2026-08-27-connector-oauth-design.md`:
///
///   * `+ Connect account` opens an inline form rendered from
///     [ConnectorsState.catalog] — see [_grantForm] — which pushes
///     [ConnectorsClient.grantUrl] rather than explaining that the web is
///     needed.
///   * Disconnect on a row whose account holds more than one connector now
///     pushes [ConnectorsClient.disconnect] unconditionally; the server
///     itself decides whether that deletes locally or replies with a
///     Google consent URL for the reduction (`connectors_channel.ex`'s
///     `disconnect` handler no longer answers `needs_web`), so there is
///     nothing left for this view to fork on client-side.
///
/// **Task 5**: the URL either flow can produce ([ConnectorsClient.oauthUrl])
/// is launched from ONE reactive site — [_ConnectorsPanelViewState.build],
/// via [_ConnectorsPanelViewState._launchIfNeeded] — regardless of whether it
/// came from a grant-form submit or a Disconnect reduction, because both
/// callers funnel through the same [ConnectorsClient.oauthUrl] field. A
/// [WidgetsBindingObserver] also refetches this panel's `state` whenever the
/// app returns from the system browser (`AppLifecycleState.resumed`) — the
/// user may have finished (or abandoned) the flow while away, and there is no
/// other signal that tells this panel to look again.
class ConnectorsPanelView extends StatefulWidget {
  const ConnectorsPanelView({super.key, required this.client});

  final ConnectorsClient client;

  /// Scopes a find.text to one row: the access badge text ("read"/"write")
  /// repeats across rows, and so does "Disconnect".
  static Key rowKey(int accountId, String connector) =>
      ValueKey('connectors-row-$accountId-$connector');

  /// So a test can tap one row's Set default without matching on the shared
  /// label.
  static Key setDefaultKey(int accountId) =>
      ValueKey('connectors-set-default-$accountId');

  /// Keyed on BOTH ids: one account can hold two connectors, so the account
  /// id alone is not unique across rows.
  static Key disconnectKey(int accountId, String connector) =>
      ValueKey('connectors-disconnect-$accountId-$connector');

  static const Key connectKey = ValueKey('connectors-connect');

  /// One row of the "Connector" picker atop the grant form, keyed on the
  /// catalog entry's own `key` — never its label, which is free-form
  /// display text a future provider could duplicate.
  static Key formConnectorKey(String connectorKey) =>
      ValueKey('connectors-form-connector-$connectorKey');

  /// One selectable option inside a rendered field: an existing account, the
  /// synthetic "new account" row, or one `choice` option. Keyed on the
  /// FIELD's own name — not "account"/"level" literally, since a future
  /// connector's field could be named anything — plus the option's own wire
  /// value, so two fields on the same form never collide and neither do two
  /// options of the same field.
  static Key formOptionKey(String fieldName, String value) =>
      ValueKey('connectors-form-option-$fieldName-$value');

  static const Key grantCancelKey = ValueKey('connectors-grant-cancel');
  static const Key grantSubmitKey = ValueKey('connectors-grant-submit');

  /// The open grant form's own container. Lets a test scope a `find.text`
  /// to inside the form specifically — needed since the Accounts section
  /// (below) can legitimately show the SAME plain email text as the form's
  /// account picker, and the two must not be conflated when a test is about
  /// one or the other.
  static const Key grantFormKey = ValueKey('connectors-grant-form');

  /// The Accounts section's per-account Remove control. Keyed on the account
  /// id alone (unlike [disconnectKey], which also needs the connector): this
  /// section renders one row per DISTINCT account, never two, so the id by
  /// itself is already unique here.
  static Key removeAccountKey(int accountId) =>
      ValueKey('connectors-remove-account-$accountId');

  /// The outcome line for a flow that finished out in the system browser.
  static const Key resultBannerKey = ValueKey('connectors-oauth-result');

  @override
  State<ConnectorsPanelView> createState() => _ConnectorsPanelViewState();
}

class _ConnectorsPanelViewState extends State<ConnectorsPanelView>
    with WidgetsBindingObserver {
  bool _formOpen = false;
  String? _connectorKey;
  Map<String, Object?> _fieldValues = const {};

  /// Set right after a launch is scheduled and cleared the moment the app
  /// comes back ([didChangeAppLifecycleState]) — the window during which the
  /// user is presumed to be away in the system browser, not a flag this view
  /// otherwise manages.
  bool _waitingForBrowser = false;

  @override
  void initState() {
    super.initState();
    // Registered here, not in build: build can run many times for one
    // mounted panel, and an observer must be added exactly once per State or
    // a single resume would refetch (and reset _waitingForBrowser) once per
    // registration instead of once.
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    // MUST run before this State is torn down: WidgetsBinding holds a raw
    // reference to every registered observer for the life of the app, not
    // for the life of the widget that registered it. Skip this and the
    // observer leaks past this panel's own lifetime — the next resume (of
    // ANY screen, not just this one) calls didChangeAppLifecycleState on a
    // disposed State, which still holds `widget.client` and would refetch a
    // topic this panel no longer has any business asking about (see the
    // moduledoc above and connectors_client.dart's ConnectorsClient.close).
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    // The user is presumed back from the browser: whatever the connect/
    // disconnect flow did (or didn't) do server-side, this panel's cached
    // `state` predates it, so ask again. There is no narrower signal — the
    // server has no way to tell this socket "the OAuth callback just landed"
    // — so every resume refetches, not only ones that follow a launch.
    widget.client.refetch();
    setState(() => _waitingForBrowser = false);
  }

  /// The one launch site both a grant-form submit and a Disconnect reduction
  /// funnel through — see the class doc. Scheduled on the post-frame
  /// callback, not run inline from `build`: [ConnectorsClient.ackOauthUrl]
  /// calls `notifyListeners()`, and calling that synchronously from inside
  /// the `AnimatedBuilder` `builder` this runs in would be a rebuild
  /// requested in the middle of a build already in progress.
  ///
  /// Does NOT guard against being scheduled more than once for the SAME
  /// reply: the "launched exactly once" property belongs to
  /// [ConnectorsClient.ackOauthUrl]. It nulls [ConnectorsClient.oauthUrl]
  /// before this callback launches anything, so `build`'s NEXT call passes
  /// this method `null` and it does nothing — a second callback scheduled
  /// for the same reply would find the same thing true by then. An earlier
  /// version of this method carried its own `_launchScheduled` flag for the
  /// same purpose; the 2026-08-27 whole-branch review found it survived
  /// deletion with the whole suite still green (mutating it out broke
  /// nothing), and could not construct a case where `build` runs twice for
  /// the same unacked reply inside one frame to prove it load-bearing.
  /// Removed rather than kept as untested code that looked like it was
  /// doing something.
  void _launchIfNeeded(String? url) {
    if (url == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Acked BEFORE launching: url_launcher hands the intent to the OS and
      // returns almost immediately, but there is no reason to let a
      // pathological double-callback race ack against a second launch of the
      // same url — ack first closes that window regardless.
      widget.client.ackOauthUrl();
      setState(() {
        _waitingForBrowser = true;
        // The request has left for the browser, so this form has done its
        // job — and it cannot be meaningfully resubmitted, because whatever
        // happens next happens at Google. Left open, it is still sitting
        // there filled in when the user comes back, which reads as "that
        // didn't take" at exactly the moment it did.
        _resetForm();
      });
      unawaited(
        launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
      );
    });
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: widget.client,
        builder: (context, _) {
          final state = widget.client.state;
          _launchIfNeeded(widget.client.oauthUrl);
          // The drawer can open before the panel's first `state` push lands.
          if (state == null) return const SizedBox.shrink();
          final connections = state.connections;
          final bottomInset = MediaQuery.of(context).viewInsets.bottom;
          return Padding(
            // Same rationale as memory_panel.dart:84-90 and
            // books_panel.dart:124-128: guarantees there is scroll room
            // below the last field for a focused field's own
            // scrollPadding-driven showOnScreen to actually scroll into.
            // Nothing rendered by THIS panel is a TextField today — every
            // field type implemented so far (`account_select`, `choice`) is
            // tap-to-select, and the design defers `text`/`secret` until a
            // real non-Google connector needs them (spec §5) — so there is
            // no per-field scrollPadding half to pair it with yet. Kept
            // anyway, unconditionally, the same way books_panel.dart and
            // memory_panel.dart do: it costs nothing idle, and a future
            // field type that DOES need a keyboard needs this half already
            // in place.
            padding: EdgeInsets.only(bottom: bottomInset),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_waitingForBrowser) _waitingBanner(),
                if (widget.client.oauthResult != null)
                  _resultBanner(widget.client.oauthResult!),
                if (widget.client.requestError != null)
                  _errorBanner(widget.client.requestError!),
                if (connections.isEmpty)
                  Text(
                    'No connections.',
                    style: TextStyle(
                      fontSize: 14,
                      color: M.ink.withValues(alpha: 0.5),
                    ),
                  )
                else
                  // Grouped by account, each group in the server's own order
                  // and the groups in the order their accounts first appear —
                  // see _accountSummaries. Nothing is re-sorted.
                  for (final a in _accountSummaries(connections))
                    _accountGroup(a),
                const SizedBox(height: 12), // space-y-3
                _connectButton(state),
                if (_formOpen) _grantForm(state),
              ],
            ),
          );
        },
      );

  /// Shown from the moment a launch fires until the app resumes (see
  /// [didChangeAppLifecycleState]) — the window during which the user is
  /// presumed to be away in the system browser.
  ///
  /// The sign-in sentence used to say the opposite — retry from here, it
  /// won't pick back up on its own — because `/auth/google/connect` sits
  /// behind `require_user` (`server/lib/app_web/router.ex`) and a signed-out
  /// browser was bounced to `/login` with the grant request discarded.
  /// `UserAuth.store_return_to/1` now records the refused GET and
  /// `GoogleAuthController.handle_login/2` resumes it after sign-in, so the
  /// flow really does continue. If either of those is ever removed, this
  /// copy goes back to telling the user to retry from here.
  Widget _waitingBanner() => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          "Finishing in your browser — come back here once you're done. If "
          'it asks you to sign in first, sign in there and it will pick up '
          'where it left off.',
          style: TextStyle(fontSize: 12, color: M.ink.withValues(alpha: 0.6)),
        ),
      );

  /// Surfaces [ConnectorsClient.requestError] — the ONLY visible sign a
  /// `set_default`/`disconnect`/`grant_url` push was refused. Before this,
  /// a `bad_request` reply (e.g. the grant form's old `new` + `none`
  /// default — the whole-branch review's HIGH finding) left the panel
  /// looking exactly like it did before the tap: no dialog, no snackbar,
  /// nothing. Same red as [_unknownField]'s failure text; disappears the
  /// moment a new request goes out (`ConnectorsClient._push`'s doc).
  /// The outcome of a flow that finished in the system browser, delivered by
  /// deep link (see [ConnectorsClient.oauthResult] and lib/deep_link.dart).
  ///
  /// The copy is written HERE rather than sent by the server, and the link
  /// carries a bounded status rather than a message, for one reason: an
  /// `intent-filter` is open to every app on the device, so a free-text field
  /// would let any of them write whatever it liked into a banner inside
  /// Henry.
  ///
  /// Success is deliberately modest. The link says the flow reached its end,
  /// not what changed — the account list below, refetched on the same resume,
  /// is what actually reports that.
  Widget _resultBanner(ConnectorsOauthResult result) => Padding(
        key: ConnectorsPanelView.resultBannerKey,
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          switch (result) {
            ConnectorsOauthResult.ok =>
              'Done — your connections are up to date below.',
            ConnectorsOauthResult.failed =>
              "That didn't finish, so nothing changed. You can try again.",
          },
          style: TextStyle(
            fontSize: 12,
            color: result == ConnectorsOauthResult.ok
                ? M.ink.withValues(alpha: 0.6)
                : _dangerRed,
          ),
        ),
      );

  Widget _errorBanner(String message) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          message,
          style: const TextStyle(fontSize: 12, color: _dangerRed),
        ),
      );

  /// One connector row, rendered INSIDE its account's group — so unlike the
  /// web's `voice_modals.ex:383-414`, it carries no email: the group header
  /// above it already names the account, once, instead of every row repeating
  /// it.
  ///
  /// That repetition is what forced this redesign. The flat row tried to fit
  /// label + email + three controls on one line; at 360dp (the phone this is
  /// laid out for) BOTH text halves ellipsised, so `Google…` and `Google C…`
  /// were the same connector on different accounts and no row could be told
  /// from any other. Removing the email frees roughly 150dp — enough for the
  /// label to render whole.
  ///
  /// Disconnect is an icon here for the last of that width. It is safe to
  /// shrink precisely because it is not the confirmation: tapping it opens
  /// [_confirmDisconnect], which spells out in words what is about to happen
  /// and (on a multi-connector account) that it means a trip to the browser.
  /// The icon is labelled for screen readers, which the bare text row was
  /// not obliged to do and this is.
  ///
  /// `power`, NOT `xMark`: the drawer's own close control is an xMark, and a
  /// second one inside every row is ambiguous — "does this dismiss the panel
  /// or drop my connection?". The first version used xMark and the drawer
  /// test caught it immediately, by no longer being able to say which ✕ it
  /// meant to tap. `trash` was the other candidate and over-promises: on a
  /// multi-connector account this does not delete anything, it opens Google's
  /// consent page to narrow the grant.
  Widget _row(Connection c) => Padding(
        key: ConnectorsPanelView.rowKey(c.accountId, c.connector),
        padding: const EdgeInsets.fromLTRB(12, 2, 0, 2), // indented under its account
        child: Row(
          children: [
            Expanded(
              child: Text(
                c.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14, color: M.ink),
              ),
            ),
            // The default badge/button pair appears ONLY when at least two
            // accounts can reach this connector — with one there is nothing
            // to choose between, so the web hides the whole span
            // (voice_modals.ex:391). `showsDefault` is computed server-side;
            // this view must not re-derive it.
            if (c.showsDefault) ...[
              const SizedBox(width: 8),
              if (c.isDefault)
                _badge('default', primary: true)
              else
                _ghostButton(
                  key: ConnectorsPanelView.setDefaultKey(c.accountId),
                  label: 'Set default',
                  onTap: () => widget.client.setDefault(c.accountId),
                ),
            ],
            const SizedBox(width: 8),
            _badge(c.access),
            const SizedBox(width: 4),
            _iconButton(
              key: ConnectorsPanelView.disconnectKey(c.accountId, c.connector),
              semanticLabel: 'Disconnect ${c.label} (${c.email})',
              onTap: () => _confirmDisconnect(context, c),
            ),
          ],
        ),
      );

  /// An icon affordance with a real hit target and a screen-reader name.
  ///
  /// 32x32: below Material's 48dp guidance, which is the deliberate trade for
  /// fitting a whole connector label on a 360dp line. Acceptable HERE, and
  /// not a precedent for the panel's other controls, because every tap lands
  /// on a confirmation dialog rather than on the destructive act itself — a
  /// mis-tap costs one "Cancel", not a connection.
  Widget _iconButton({
    required Key key,
    required String semanticLabel,
    required VoidCallback onTap,
  }) =>
      Semantics(
        button: true,
        label: semanticLabel,
        child: GestureDetector(
          key: key,
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: const SizedBox(
            width: 32,
            height: 32,
            child: Center(
              child: HeroIconView(HeroIcon.power, size: 16, color: M.inkDim),
            ),
          ),
        ),
      );

  /// A group's header: the account, named once, with the control that drops
  /// it whole. "Remove" rather than "Remove account" — the row it sits on IS
  /// the account, so the noun was saying the same thing twice, and the words
  /// it costs are the ones the email needs.
  Widget _accountGroup(_AccountSummary a) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      a.email,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14, color: M.ink),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _ghostButton(
                    key: ConnectorsPanelView.removeAccountKey(a.accountId),
                    label: 'Remove',
                    onTap: () => _confirmRemoveAccount(context, a),
                  ),
                ],
              ),
            ),
            for (final c in a.connections) _row(c),
          ],
        ),
      );

  /// Disconnect is destructive AND, on an account that holds more than one
  /// connector, it leaves the app: Google will not narrow a grant without
  /// re-consent, so the reduction has to run on its consent page in a browser.
  ///
  /// Both facts are worth saying BEFORE acting. An earlier version of this
  /// panel showed a sheet explaining the browser hop but could not perform it;
  /// when the hop started working the sheet was deleted and nothing replaced
  /// it, so a tap silently threw the user into a browser. That reads as a bug
  /// even though the behaviour is correct — which is exactly what happened the
  /// first time this shipped.
  ///
  /// [Connection.onlyGrant] decides only WHAT WE SAY. The server re-derives it
  /// authoritatively before acting (`connectors_channel.ex`'s `disconnect`),
  /// because a panel rendered before this account gained a second connector
  /// would otherwise delete a connection the user still wants. Same rule as
  /// the Books panel's `clear_book` key: a client-side copy is a precondition
  /// for the copy, never the decision.
  Future<void> _confirmDisconnect(BuildContext context, Connection c) async {
    final question = c.onlyGrant
        ? 'Disconnect ${c.label} (${c.email})?'
        : '${c.email} also uses another connector, and Google only narrows '
            'access by asking again. Continue in your browser to remove '
            '${c.label}?';

    if (await _confirm(context, question)) {
      widget.client.disconnect(accountId: c.accountId, connector: c.connector);
    }
  }

  /// Removing an account is destructive, AND — unlike a plain local delete —
  /// it is not guaranteed to be complete when it finishes: the server tries
  /// to revoke the account's Google grant first, but a revoke failure does
  /// NOT block the local delete that follows (`connectors_channel.ex`'s
  /// `remove_account` — deliberately, to avoid recreating the deadlock
  /// commit 09399ae fixed, where a dead token made an account permanently
  /// unmodifiable). That means a failed revoke leaves Google still listing
  /// the grant at myaccount.google.com/permissions even though this app has
  /// forgotten the account entirely. The copy below says that up front —
  /// it must never imply the app has fully severed access on its own.
  Future<void> _confirmRemoveAccount(
      BuildContext context, _AccountSummary a) async {
    final question = 'Remove ${a.email}? This deletes it here and asks '
        "Google to revoke access — but if that fails, Google may still list "
        'it until you remove it yourself at '
        'myaccount.google.com/permissions.';

    if (await _confirm(context, question)) {
      widget.client.removeAccount(a.accountId);
    }
  }

  /// `.badge` base + `.badge-primary` (the `default` badge) / `.badge-ghost`
  /// (the access badge) variants — app.css:1176-1197.
  Widget _badge(String text, {bool primary = false}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: primary
              ? M.you.withValues(alpha: 0.20)
              : const Color(0x05FFFFFF), // rgba(255,255,255,0.02)
          border: Border.all(
            // `.badge-ghost` overrides background and color only — the
            // border stays the base `.badge` hairline.
            color: primary ? M.you.withValues(alpha: 0.55) : M.hairline,
          ),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 10,
            fontFamily: kDisplayFamily,
            fontWeight: FontWeight.w600,
            letterSpacing: MType.track(10, 0.03),
            color: primary ? M.youSoft : M.inkFaint,
          ),
        ),
      );

  /// `.btn` + `.btn-ghost` (Set default / Disconnect) — app.css:1118-1124 +
  /// 1136-1139: transparent fill and border.
  Widget _ghostButton({
    required Key key,
    required String label,
    required VoidCallback onTap,
  }) =>
      GestureDetector(
        key: key,
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.transparent,
            border: Border.all(color: Colors.transparent),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              fontFamily: kDisplayFamily,
              fontWeight: FontWeight.w600,
              color: M.inkDim,
            ),
          ),
        ),
      );

  /// `.btn` with no variant — app.css:1118-1124: hairline border, faint
  /// fill. Mirrors the web's `grant_open` handler
  /// (`conversation_live.ex:342-346`): tapping this ALWAYS (re)opens the
  /// form fresh on the first catalog entry's defaults, even if a form is
  /// already open with a different selection in progress — the web does not
  /// toggle either.
  Widget _connectButton(ConnectorsState state) => SizedBox(
        width: double.infinity,
        child: GestureDetector(
          key: ConnectorsPanelView.connectKey,
          behavior: HitTestBehavior.opaque,
          onTap: () => _openForm(state.catalog),
          child: Container(
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0x06FFFFFF), // rgba(255,255,255,0.025)
              border: Border.all(color: M.hairline),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Text(
              '+ Connect account',
              style: TextStyle(
                fontSize: 13,
                fontFamily: kDisplayFamily,
                fontWeight: FontWeight.w600,
                color: M.inkDim,
              ),
            ),
          ),
        ),
      );

  void _openForm(List<ConnectorSpec> catalog) {
    setState(() {
      _formOpen = true;
      final first = catalog.isEmpty ? null : catalog.first;
      _connectorKey = first?.key;
      _fieldValues = first == null ? const {} : _defaultsFor(first);
    });
  }

  void _selectConnector(ConnectorSpec spec) {
    setState(() {
      _connectorKey = spec.key;
      _fieldValues = _defaultsFor(spec);
    });
  }

  /// A fresh connector selection needs fresh field values: the FIELDS
  /// themselves differ per connector (that is the entire point of the
  /// catalog — spec §5), so a value keyed by one connector's field name
  /// could be nonsense, or worse, coincidentally valid, once a different
  /// connector is picked.
  ///
  /// The server's own [FormField.defaultValue] wins whenever it is present —
  /// see that field's doc for why the RULE for what a field should start on
  /// belongs to the server, not this renderer. This used to default a
  /// `choice` field to `options.first` unconditionally, which coincided with
  /// Google's Access field's "none" (`Connectors.access_levels/1` lists
  /// `:none` first, because it is meaningful for an EXISTING account) and
  /// opened the grant form on a combination the channel refuses outright —
  /// the whole-branch review's HIGH finding. `options.first` survives only
  /// as the fallback for a field the server sent no default for (or whose
  /// stated default isn't actually one of its own options — a malformed
  /// catalog entry should still produce a selectable field, not a blank
  /// one). None of this special-cases a field literally named "level": the
  /// same rule applies to whatever `choice` field a future connector sends.
  Map<String, Object?> _defaultsFor(ConnectorSpec spec) {
    final values = <String, Object?>{};
    for (final field in spec.fields) {
      switch (_kindOf(field.type)) {
        case _FieldKind.accountSelect:
          // No `options` arrive for this type at all (the account list is
          // built client-side from live connections — see
          // _accountSelectField's doc), so there is nothing to validate
          // `defaultValue` against; 'new' is the fallback either way.
          values[field.name] = field.defaultValue ?? 'new';
        case _FieldKind.choice:
          final serverDefault = field.defaultValue;
          final isValidOption =
              serverDefault is String && field.options.any((o) => o.value == serverDefault);
          if (isValidOption) {
            values[field.name] = serverDefault;
          } else if (field.options.isNotEmpty) {
            values[field.name] = field.options.first.value;
          }
        case _FieldKind.unknown:
          break; // Nothing sane to default an unrenderable field to.
      }
    }
    return values;
  }

  void _setField(String name, Object? value) =>
      setState(() => _fieldValues = {..._fieldValues, name: value});

  void _cancelForm() => setState(_resetForm);

  /// The form's reset, shared by [_cancelForm] and [_launchIfNeeded] so the
  /// two can never drift into clearing different halves of it. Not wrapped in
  /// setState itself — one caller is already inside one.
  void _resetForm() {
    _formOpen = false;
    _connectorKey = null;
    _fieldValues = const {};
  }

  void _submit(String connectorKey) {
    // Once the reply lands, widget.client.oauthUrl carries it and build's
    // _launchIfNeeded (the one launch site — see the class doc) opens it.
    widget.client
        .grantUrl(connector: connectorKey, fields: Map.of(_fieldValues));
  }

  /// The port of `connectors_panel/1`'s grant `<div :if={@grant}>` block
  /// (`voice_modals.ex` ~422-479) — generic over [ConnectorsState.catalog]
  /// rather than switching on "calendar" or "gmail" by name. A catalog
  /// entry this client has never seen (a future Home Assistant/CouchDB row)
  /// renders here exactly the way Google's own two entries do, because
  /// nothing below reads `spec.key` to decide WHAT to draw — only which
  /// entry is currently selected.
  Widget _grantForm(ConnectorsState state) {
    final catalog = state.catalog;
    if (catalog.isEmpty) return const SizedBox.shrink();
    final spec = catalog.firstWhere(
      (c) => c.key == _connectorKey,
      orElse: () => catalog.first,
    );
    return Container(
      key: ConnectorsPanelView.grantFormKey,
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: M.hairline),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Add a connection',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: M.ink,
            ),
          ),
          const SizedBox(height: 8),
          _fieldLabel('Connector'),
          // Every catalog entry, server-ordered (Connectors.all/0) — do not
          // re-sort. Rendering this list generically (label + key only) is
          // what proves a third, invented connector shows up unmodified.
          for (final c in catalog)
            _optionRow(
              key: ConnectorsPanelView.formConnectorKey(c.key),
              label: c.label,
              selected: c.key == spec.key,
              onTap: () => _selectConnector(c),
            ),
          for (final field in spec.fields) _field(state, spec, field),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                key: ConnectorsPanelView.grantCancelKey,
                onPressed: _cancelForm,
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                key: ConnectorsPanelView.grantSubmitKey,
                onPressed: () => _submit(spec.key),
                style: OutlinedButton.styleFrom(foregroundColor: M.ink),
                child: const Text('Grant'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// One field of the selected connector's form. A `switch` over
  /// [_FieldKind] — not the raw wire string — WITH NO DEFAULT ARM:
  /// [_FieldKind] is an enum, so the analyzer enforces this is exhaustive at
  /// compile time. Add a fourth kind (the design's deferred `text`/`secret`,
  /// spec §5) and forget to add its case here, and this fails to COMPILE —
  /// it can never silently render nothing for a kind nobody taught this
  /// switch about. The same exhaustiveness discipline `main.dart`'s
  /// `_openPanel` uses over `MeridianTab`, where a `default` arm had
  /// previously swallowed a whole station silently.
  ///
  /// [_FieldKind.unknown] is the one arm this switch DOES need: a `type`
  /// string this client has never heard of on the wire is not something the
  /// compiler can rule out (see [_kindOf]), so [_unknownField] renders a
  /// visible failure instead.
  Widget _field(ConnectorsState state, ConnectorSpec spec, FormField field) {
    final value = _fieldValues[field.name];
    return switch (_kindOf(field.type)) {
      _FieldKind.accountSelect =>
        _accountSelectField(state, spec, field, value),
      _FieldKind.choice => _choiceField(field, value),
      _FieldKind.unknown => _unknownField(field),
    };
  }

  /// The one field type that needs client knowledge beyond the descriptor
  /// itself (spec §5, §6): the server sends no `options` for this type, so
  /// the account list is built from [ConnectorsState.connections] —
  /// deduplicated to one row per account, since one account can hold two
  /// connectors and therefore appear twice in that list — plus a synthetic
  /// "new account" row this client invents. This does NOT special-case the
  /// field's `name` ("account" today, per the real catalog): a future
  /// connector could call this field anything and it renders identically,
  /// keyed only on `type`. [spec] is needed only to label that synthetic
  /// row ([_newAccountLabel]) — nothing else here reads it.
  Widget _accountSelectField(
      ConnectorsState state, ConnectorSpec spec, FormField field, Object? value) {
    final seen = <int>{};
    final accounts = [
      for (final c in state.connections)
        if (seen.add(c.accountId)) c,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _fieldLabel(field.label),
        _optionRow(
          key: ConnectorsPanelView.formOptionKey(field.name, 'new'),
          label: _newAccountLabel(spec),
          selected: value == 'new',
          onTap: () => _setField(field.name, 'new'),
        ),
        for (final a in accounts)
          _optionRow(
            key: ConnectorsPanelView.formOptionKey(
                field.name, a.accountId.toString()),
            label: a.email,
            selected: value == a.accountId,
            onTap: () => _setField(field.name, a.accountId),
          ),
      ],
    );
  }

  /// "New Google account" — byte-exact against `voice_modals.ex`'s literal
  /// `<option>` (~438) for Google's own two connectors today, but not a
  /// hardcoded string: it is built from the catalog entry's own `provider`,
  /// so a future provider gets its own label with no Dart change, the same
  /// generality the catalog itself is designed around (spec §5).
  String _newAccountLabel(ConnectorSpec spec) =>
      'New ${_capitalize(spec.provider)} account';

  String _capitalize(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  /// A plain multiple-choice field — e.g. Google's access level (with
  /// none/read/write from `Connectors.access_levels/1`), or an invented
  /// connector's own options with its own values. Nothing here reads
  /// `field.name`; every option comes straight from [FormField.options], so
  /// a catalog offering two options or five renders exactly that many, never
  /// a hardcoded three.
  Widget _choiceField(FormField field, Object? value) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _fieldLabel(field.label),
          for (final opt in field.options)
            _optionRow(
              key: ConnectorsPanelView.formOptionKey(field.name, opt.value),
              label: opt.label.isEmpty ? opt.value : opt.label,
              selected: value == opt.value,
              onTap: () => _setField(field.name, opt.value),
            ),
        ],
      );

  /// [_FieldKind.unknown]'s arm: a VISIBLE failure, never a blank field. A
  /// server that ships a new field type ahead of this client (Home
  /// Assistant's eventual `text`, a future `secret`) must not have its whole
  /// connector quietly lose one input — the user needs to see that
  /// something did not render, not wonder why "Grant" does not do what they
  /// expect.
  Widget _unknownField(FormField field) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(
          'Unsupported field "${field.label.isEmpty ? field.name : field.label}" '
          '(type: ${field.type})',
          style: const TextStyle(fontSize: 13, color: _dangerRed),
        ),
      );

  /// One tappable row shared by the connector picker, the account picker,
  /// and any `choice` field — the same "row list, highlight the current
  /// pick" idiom `books_panel.dart`'s `_bookRow` uses for "Switch book".
  Widget _optionRow({
    required Key key,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) =>
      GestureDetector(
        key: key,
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: selected ? M.you.withValues(alpha: 0.12) : null,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 14,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              color: selected ? M.you : M.ink,
            ),
          ),
        ),
      );

  /// The 12px / `M.ink` @ 60% field-label recipe every other panel's
  /// `_SectionLabel` uses, kept as a bare function here rather than a class
  /// since this form has no section headers of its own beyond field labels.
  Widget _fieldLabel(String text) => Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 4),
        child: Text(
          text,
          style: TextStyle(fontSize: 12, color: M.ink.withValues(alpha: 0.6)),
        ),
      );
}

/// One group in the panel: a DISTINCT connected account and every connector
/// it holds, derived from [ConnectorsState.connections] rather than sent by
/// the server as its own list.
class _AccountSummary {
  const _AccountSummary({
    required this.accountId,
    required this.email,
    required this.connections,
  });

  final int accountId;
  final String email;

  /// This account's rows, in the order the server sent them.
  final List<Connection> connections;
}

/// Groups [connections] by `accountId`, keeping one [_AccountSummary] per
/// account.
///
/// This is PRESENTATION grouping, not a business rule: the server already
/// decided (and sent) the row order — `{label, email}`, per
/// `connectors_channel.ex`'s `rows/1` — and this function does not
/// re-derive or override that order in any way that would matter server-side;
/// it only collapses each account's (possibly two) rows down to the one it
/// first appears in, for a section that has nothing to do with connectors or
/// access levels. The standing rule on this project is that the SERVER
/// decides ordering (see e.g. `connectors_client.dart`'s "never re-sort"
/// warnings on [Connection] and [ConnectorSpec]) — this was read and
/// considered before writing this function, and grouping-without-reordering
/// is why it doesn't violate that rule: every account here keeps the
/// position of its FIRST row in the server's own list, nothing is
/// reshuffled, and no new order is invented that the server didn't already
/// imply.
List<_AccountSummary> _accountSummaries(List<Connection> connections) {
  final order = <int>[];
  final byAccount = <int, List<Connection>>{};
  final emails = <int, String>{};

  for (final c in connections) {
    if (byAccount.putIfAbsent(c.accountId, () => []).isEmpty) {
      order.add(c.accountId);
      emails[c.accountId] = c.email;
    }
    byAccount[c.accountId]!.add(c);
  }

  return [
    for (final id in order)
      _AccountSummary(
        accountId: id,
        email: emails[id]!,
        connections: byAccount[id]!,
      ),
  ];
}

/// Mirrors `books_panel.dart` and `memory_panel.dart`'s `_confirm`. Returns
/// false on a dismissed dialog (a barrier tap or back gesture pops null) —
/// this gates a destructive action, so an ambiguous dismissal must never read
/// as consent.
Future<bool> _confirm(BuildContext context, String question) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      content: Text(question),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel')),
        TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('OK')),
      ],
    ),
  );
  return ok ?? false;
}
