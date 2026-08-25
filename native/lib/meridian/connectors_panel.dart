import 'package:flutter/material.dart';

import '../panels/connectors_client.dart';
import 'tokens.dart';

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
/// DEAD ENDS BY DESIGN (Task 5 wires these up): `+ Connect account` has no
/// `onTap` yet, and Disconnect always pushes the plain `disconnect` — the
/// `onlyGrant: false` fork (which needs Google's consent page, surfaced via
/// `client.needsWeb`) is not built here.
class ConnectorsPanelView extends StatelessWidget {
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
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: client,
        builder: (context, _) {
          final state = client.state;
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
                  onTap: () => client.setDefault(c.accountId),
                ),
            ],
            const SizedBox(width: 8),
            _badge(c.access),
            const SizedBox(width: 8),
            _ghostButton(
              key: ConnectorsPanelView.disconnectKey(c.accountId, c.connector),
              label: 'Disconnect',
              // Task 5 replaces this with the only_grant fork (a needs_web
              // refusal explains the alternative instead of silently no-op'ing).
              onTap: () =>
                  client.disconnect(accountId: c.accountId, connector: c.connector),
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
  /// fill. Rendered here but wired to nothing yet (Task 5 gives it its
  /// grant sheet); its copy test lands now.
  Widget _connectButton() => SizedBox(
        width: double.infinity,
        child: GestureDetector(
          key: ConnectorsPanelView.connectKey,
          behavior: HitTestBehavior.opaque,
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
