import 'package:flutter/material.dart' hide FormField;

import '../panels/connectors_client.dart';
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
/// Launching the URL either flow can produce ([ConnectorsClient.oauthUrl])
/// and refetching on app resume are **Task 5**, not this file's job — see
/// the marker comment in [_ConnectorsPanelViewState._submit]. This view's
/// job ends at "the form pushes `grant_url` and the client has the URL."
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

  @override
  State<ConnectorsPanelView> createState() => _ConnectorsPanelViewState();
}

class _ConnectorsPanelViewState extends State<ConnectorsPanelView> {
  bool _formOpen = false;
  String? _connectorKey;
  Map<String, Object?> _fieldValues = const {};

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: widget.client,
        builder: (context, _) {
          final state = widget.client.state;
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
                if (connections.isEmpty)
                  Text(
                    'No connections.',
                    style: TextStyle(
                      fontSize: 14,
                      color: M.ink.withValues(alpha: 0.5),
                    ),
                  )
                else
                  // Server order ({label, email}) — do not re-sort.
                  for (final c in connections) _row(c),
                const SizedBox(height: 12), // space-y-3
                _connectButton(state),
                if (_formOpen) _grantForm(state),
              ],
            ),
          );
        },
      );

  /// One row, mirroring `voice_modals.ex:383-414`'s `flex items-center
  /// gap-2`.
  Widget _row(Connection c) => Padding(
        key: ConnectorsPanelView.rowKey(c.accountId, c.connector),
        padding: const EdgeInsets.symmetric(vertical: 2), // space-y-1
        child: Row(
          children: [
            // `<span class="flex-1">{label} <span class="opacity-60">
            // ({email})</span></span>`
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      c.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14, color: M.ink),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      '(${c.email})',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        color: M.ink.withValues(alpha: 0.6),
                      ),
                    ),
                  ),
                ],
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
            const SizedBox(width: 8),
            _ghostButton(
              key: ConnectorsPanelView.disconnectKey(c.accountId, c.connector),
              label: 'Disconnect',
              // Unconditional now: the server re-derives `only_grant` itself
              // and either deletes locally (fresh `state` follows) or
              // replies with a Google consent URL for the reduction
              // (`connectors_channel.ex`'s `disconnect` handler) — there is
              // no longer a dead end for this view to fork around
              // client-side. Launching that URL is Task 5's job.
              onTap: () => widget.client
                  .disconnect(accountId: c.accountId, connector: c.connector),
            ),
          ],
        ),
      );

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
  /// Defaults are a generic, arbitrary "first option wins" rule — this does
  /// NOT reproduce the web's `default_level/1` (`conversation_live.ex:672`,
  /// which defaults to the LAST, most-privileged access level): that rule
  /// is Google-specific ("write" beats "read" beats "none"), and baking it
  /// in here would mean special-casing a field literally named "level",
  /// exactly what this renderer exists to avoid.
  Map<String, Object?> _defaultsFor(ConnectorSpec spec) {
    final values = <String, Object?>{};
    for (final field in spec.fields) {
      switch (_kindOf(field.type)) {
        case _FieldKind.accountSelect:
          values[field.name] = 'new';
        case _FieldKind.choice:
          if (field.options.isNotEmpty) {
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

  void _cancelForm() => setState(() {
        _formOpen = false;
        _connectorKey = null;
        _fieldValues = const {};
      });

  void _submit(String connectorKey) {
    widget.client
        .grantUrl(connector: connectorKey, fields: Map.of(_fieldValues));
    // TASK 5 MARKER: once widget.client.oauthUrl carries this request's
    // reply, launch it in the system browser (url_launcher,
    // LaunchMode.externalApplication) and call ackOauthUrl() so a later
    // rebuild does not relaunch it — see the design's §6. This task's job
    // ends here: the form has pushed grant_url, and the client will have
    // the URL once the reply lands.
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
