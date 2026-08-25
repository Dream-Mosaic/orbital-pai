import 'package:flutter/material.dart';

import '../panels/connectors_client.dart';
import '../voice/voice_controller.dart';
import 'tokens.dart';

/// Shown for `+ Connect account`. Names the ROUTE, and says "isn't in the app
/// yet" rather than anything that reads as a fault: connecting an account is a
/// consent round-trip through Google's own sign-in page, and that is roadmap
/// phase 6, not a bug.
///
/// The route was checked, not assumed: on the web Connectors is a BOTTOM-NAV
/// station (conversation_live.ex:929-937), NOT a row inside Settings — the
/// web's settings panel has only Memory and Voice Lock
/// (voice_modals.ex:662-679). The design's draft wording said
/// "Settings -> Connectors", which would send the user somewhere that does not
/// exist.
const String kConnectAccountMessage =
    "Connecting an account needs Google's sign-in page, which isn't in the "
    'app yet. Open ${VoiceController.assistantName} in a browser and use the '
    'Connectors panel there.';

/// Shown for Disconnect on a row whose account holds another connector.
///
/// The web implements "remove one connector" as a re-consent with fewer
/// scopes (conversation_live.ex:336-337), not a local scope edit, because
/// editing our stored scope would leave a live Google token holding more
/// access than our record claims. So this is deferred for a REASON, and the
/// sentence says what is actually needed.
const String kReduceAccessMessage =
    'This account has more than one connection, so removing just this one '
    "needs Google's consent page, which isn't in the app yet. Open "
    '${VoiceController.assistantName} in a browser and use the Connectors '
    'panel there.';

/// The Connectors drawer's contents — the port of `connectors_panel/1` in
/// `lib/app_web/components/voice_modals.ex` (~412-455): one row per
/// (account, connector) grant, each with its label, email, an optional
/// default badge/button pair, an access badge, and a Disconnect button,
/// followed by a `+ Connect account` button.
///
/// Server-authoritative, same pattern as the other panels: every write
/// pushes and the UI re-renders from the next `state`. [Connection] arrives
/// already sorted `{label, email}` and this view must NOT re-sort it, and
/// `showsDefault`/`onlyGrant` arrive pre-derived — this view must not
/// re-derive either.
///
/// Both dead ends (`+ Connect account`, and Disconnect on a row whose
/// account holds another connector) stay enabled and explain themselves —
/// see [kConnectAccountMessage] and [kReduceAccessMessage].
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

  @override
  State<ConnectorsPanelView> createState() => _ConnectorsPanelViewState();
}

class _ConnectorsPanelViewState extends State<ConnectorsPanelView> {
  @override
  void initState() {
    super.initState();
    widget.client.addListener(_onClientChanged);
  }

  @override
  void dispose() {
    widget.client.removeListener(_onClientChanged);
    super.dispose();
  }

  /// A `needs_web` refusal can only arrive from the SERVER, and only when this
  /// panel was stale — it rendered `only_grant: true` for a row that has since
  /// gained a second connector. The local fork below catches the common case
  /// without a round trip; this catches the race. Two defences, not one
  /// duplicated: the server's is the one that actually protects the data.
  void _onClientChanged() {
    if (!widget.client.needsWeb || !mounted) return;
    widget.client.ackNeedsWeb();
    _explain(kReduceAccessMessage);
  }

  /// Mirrors memory_panel.dart's `_confirm`, minus the choice: there is
  /// nothing to decide here, only something to read. AlertDialog rather than a
  /// bottom sheet because it is the idiom this app already has three of
  /// (memory_panel.dart:262, settings_panel.dart:136, voice_screen.dart:68).
  Future<void> _explain(String message) => showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: widget.client,
        builder: (context, _) {
          final state = widget.client.state;
          // The drawer can open before the panel's first `state` push lands.
          if (state == null) return const SizedBox.shrink();
          final connections = state.connections;
          return Column(
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
              _connectButton(),
            ],
          );
        },
      );

  /// One row, mirroring `voice_modals.ex:416-447`'s `flex items-center
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
            // (voice_modals.ex:424). `showsDefault` is computed server-side;
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
              onTap: () {
                // The local fork. `onlyGrant` is the SERVER's answer, carried
                // on the row; the client does not recompute it. False means
                // this is a scope reduction, which is a re-consent, so ask
                // nothing and explain instead — a round trip whose only
                // possible answer is `needs_web` is a round trip worth
                // skipping. The server re-derives it anyway for the stale
                // case; see _onClientChanged.
                if (!c.onlyGrant) {
                  _explain(kReduceAccessMessage);
                  return;
                }
                widget.client
                    .disconnect(accountId: c.accountId, connector: c.connector);
              },
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
  /// fill. Connecting an account is an OAuth round trip (roadmap phase 6),
  /// so this explains rather than pushes — see [kConnectAccountMessage].
  Widget _connectButton() => SizedBox(
        width: double.infinity,
        child: GestureDetector(
          key: ConnectorsPanelView.connectKey,
          behavior: HitTestBehavior.opaque,
          onTap: () => _explain(kConnectAccountMessage),
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
}
