import 'package:flutter/material.dart';

import '../panels/settings_client.dart';
import '../voice/voice_controller.dart';
import 'tokens.dart';

/// `#voice-modal .btn-error { color: #f87171 }` — the literal Danger-zone red
/// Meridian's own CSS uses for the buttons. daisyUI's `--color-error`
/// (`oklch(58% 0.253 17.585)`) is what actually governs the plain `text-error`
/// heading (the CSS only restyles `.btn-error`, not the h3), so this is a
/// separate constant: the clipped (out-of-gamut) sRGB conversion of that
/// oklch triple, using the same method already banked as `M.success`'s
/// comment in tokens.dart.
const Color _dangerRed = Color(0xFFEA003E);

/// The Settings drawer's Voice / Danger-zone / About sections, plus the
/// Memory nav row — the port of `settings_panel/1` in
/// `lib/app_web/components/voice_modals.ex` (the function itself runs
/// ~541-682). The Account, Active-now and Switch-user sections, and the
/// Voice-Lock nav row, are still OUT of scope; see the design's §2 Scope
/// (`docs/superpowers/specs/2026-08-11-settings-panel-design.md`):
/// Switch-user is blocked on native session support (roadmap phase 7),
/// Active-now is a "who else is online" strip not worth a subscription yet.
/// Memory used to be out of scope too — it needed the layered-drawer
/// mechanic this view deliberately does not build — but that mechanic now
/// exists (`settings_drawer_host.dart`), so [onOpenMemory] is this view's
/// half of the wiring: a bare callback, with no navigation of its own.
class SettingsPanelView extends StatelessWidget {
  const SettingsPanelView({super.key, required this.client, this.onOpenMemory});

  final SettingsClient client;

  /// Null hides the Memory row entirely (e.g. a caller with nowhere to send
  /// the tap). settings_drawer_host.dart is the only caller that supplies it.
  final VoidCallback? onOpenMemory;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: client,
        builder: (context, _) {
          final state = client.state;
          // The drawer can open before the panel's first `state` push lands.
          if (state == null) return const SizedBox.shrink();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _voice(context, state),
              const SizedBox(height: 24), // space-y-6 = 1.5rem = 24px
              _dangerZone(context),
              const SizedBox(height: 24),
              _about(state),
              if (onOpenMemory != null) ...[
                const SizedBox(height: 24),
                _memoryRow(),
              ],
            ],
          );
        },
      );

  /// `voice_modals.ex:662-670` — full-width ghost row, label left, a
  /// 60%-opacity `→` right.
  Widget _memoryRow() => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onOpenMemory,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween, // justify-between
            children: [
              const Text('Memory', style: TextStyle(fontSize: 14, color: M.ink)),
              Text('→',
                  style:
                      TextStyle(fontSize: 14, color: M.ink.withValues(alpha: 0.6))),
            ],
          ),
        ),
      );

  Widget _voice(BuildContext context, SettingsState state) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _SectionLabel('Voice'),
          const SizedBox(height: 8), // space-y-2 = 0.5rem = 8px
          _toggle(
            key: const ValueKey('toggle-default_abi'),
            label: 'Default ABI (allow barge-in)',
            value: state.defaultAbi,
            onChanged: (v) => client.setPref('default_abi', v),
          ),
          const SizedBox(height: 8),
          _toggle(
            key: const ValueKey('toggle-default_ptt'),
            label: 'Default PTT (push-to-talk)',
            value: state.defaultPtt,
            onChanged: (v) => client.setPref('default_ptt', v),
          ),
          const SizedBox(height: 8),
          _toggle(
            key: const ValueKey('toggle-voice_activation'),
            label: 'Voice activation (say the wake word; wall only)',
            value: state.voiceActivation,
            onChanged: (v) => client.setPref('voice_activation', v),
          ),
          const SizedBox(height: 8),
          _toggle(
            key: const ValueKey('toggle-briefing'),
            label: 'Morning briefing (spoken your first turn that morning)',
            value: state.briefingOn,
            // '07:00' is the default the web dials in the moment this flips on
            // (voice_modals.ex's toggle_briefing handler).
            onChanged: (v) => client.setBriefing(v ? '07:00' : null),
          ),
          if (state.briefingOn) ...[
            const SizedBox(height: 8),
            _briefingTimeRow(context, state),
          ],
          const SizedBox(height: 8),
          _lockdownRow(state),
        ],
      );

  /// Mirrors the web's `data-confirm`, and voice_screen.dart's _confirmClear.
  /// Acts only on an explicit true — a dismissed dialog returns null.
  static Future<bool> _confirm(BuildContext context, String question) async {
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

  Widget _toggle({
    Key? key,
    required String label,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) =>
      Row(
        children: [
          Expanded(
            child:
                Text(label, style: const TextStyle(fontSize: 14, color: M.ink)),
          ),
          Switch(
            key: key,
            value: value,
            onChanged: onChanged,
            // #voice-modal .toggle:checked { --input-color: var(--you) } is
            // the whole of Meridian's restyle here. `activeColor` was
            // deprecated for `activeThumbColor` in this Flutter (3.44); the
            // brief's snippet predates that, same tint either way.
            activeThumbColor: M.you,
          ),
        ],
      );

  Widget _briefingTimeRow(BuildContext context, SettingsState state) => Row(
        children: [
          const Expanded(
            child: Text('Briefing time',
                style: TextStyle(fontSize: 14, color: M.ink)),
          ),
          GestureDetector(
            onTap: () async {
              final initial = _parseHHmm(state.briefingTime) ??
                  const TimeOfDay(hour: 7, minute: 0);
              final picked =
                  await showTimePicker(context: context, initialTime: initial);
              if (picked == null) return;
              final hh = picked.hour.toString().padLeft(2, '0');
              final mm = picked.minute.toString().padLeft(2, '0');
              client.setBriefing('$hh:$mm');
            },
            child: Text(
              state.briefingTime ?? '',
              style:
                  TextStyle(fontSize: 14, color: M.ink.withValues(alpha: 0.7)),
            ),
          ),
        ],
      );

  Widget _lockdownRow(SettingsState state) =>
      _LockdownSlider(client: client, relockSeconds: state.relockSeconds);

  Widget _dangerZone(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _SectionLabel('Danger zone', color: _dangerRed),
          const SizedBox(height: 8),
          _dangerButton(
            context,
            label: 'Clear conversation',
            question: 'Clear this conversation?',
            onConfirmed: client.clearTurns,
          ),
          const SizedBox(height: 8),
          _dangerButton(
            context,
            label: 'Wipe memory',
            question:
                'Forget everything ${VoiceController.assistantName} knows about you?',
            onConfirmed: client.forgetMe,
          ),
        ],
      );

  Widget _dangerButton(
    BuildContext context, {
    required String label,
    required String question,
    required VoidCallback onConfirmed,
  }) =>
      OutlinedButton(
        onPressed: () async {
          if (await _confirm(context, question)) onConfirmed();
        },
        style: OutlinedButton.styleFrom(
          foregroundColor: _dangerRed,
          side: BorderSide(color: _dangerRed.withValues(alpha: 0.4)),
        ),
        child: Text(label),
      );

  Widget _about(SettingsState state) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _SectionLabel('About'),
          const SizedBox(height: 4), // space-y-1 = 0.25rem = 4px
          Text('P.A.I v${state.appVersion}',
              style:
                  TextStyle(fontSize: 14, color: M.ink.withValues(alpha: 0.6))),
        ],
      );
}

/// Parses a server `HH:mm` string into a [TimeOfDay]; null on anything else
/// (including no briefing time set yet).
TimeOfDay? _parseHHmm(String? hhmm) {
  if (hhmm == null) return null;
  final parts = hhmm.split(':');
  if (parts.length != 2) return null;
  final h = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  if (h == null || m == null) return null;
  return TimeOfDay(hour: h, minute: m);
}

/// The lockdown-timeout slider, isolated into its own StatefulWidget so a
/// drag holds its value locally instead of round-tripping every frame
/// through the server. Mirrors the web's `phx-debounce="200"`
/// (`voice_modals.ex`'s `settings_panel/1`, the `#lockdown-form` range input)
/// but goes one step further: rather than a trailing timer, this pushes only
/// on `onChangeEnd` (the drag's release). That is strictly cheaper — one
/// `set_relock` per drag no matter how long it runs — and it also cures the
/// rubber-banding a debounce timer alone would not: the row is
/// server-authoritative (`value: state.relockSeconds`), so without a local
/// value the thumb would keep snapping back to the last-acked value while a
/// slow `state` round-trip is in flight. `_dragging` holds the in-progress
/// value so the thumb and the "Ns" label track the finger immediately, and
/// only clears back to the server's value once the drag ends and the push
/// has gone out.
class _LockdownSlider extends StatefulWidget {
  const _LockdownSlider({required this.client, required this.relockSeconds});

  final SettingsClient client;
  final int relockSeconds;

  @override
  State<_LockdownSlider> createState() => _LockdownSliderState();
}

class _LockdownSliderState extends State<_LockdownSlider> {
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final display = _dragging ?? widget.relockSeconds.toDouble();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text('Lockdown timeout (wall)',
                  style: TextStyle(fontSize: 14, color: M.ink)),
            ),
            Text('${display.round()}s',
                style: TextStyle(
                    fontSize: 14, color: M.ink.withValues(alpha: 0.7))),
          ],
        ),
        Slider(
          value: display.clamp(10, 30),
          min: 10,
          max: 30,
          divisions: 20,
          activeColor: M.you,
          // Local-only: keeps the thumb and label tracking the finger
          // without pushing a frame per pixel.
          onChanged: (v) => setState(() => _dragging = v),
          // The one and only write for the whole gesture.
          onChangeEnd: (v) {
            widget.client.setRelock(v.round());
            setState(() => _dragging = null);
          },
        ),
      ],
    );
  }
}

/// The same 12px / `M.ink` @ 60% recipe as reminders_panel.dart's
/// `_SectionLabel`, with an optional color override for the Danger-zone
/// heading (which stays red rather than dimmed ink).
class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text, {this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: TextStyle(
          fontSize: 12, // text-xs
          color: color ?? M.ink.withValues(alpha: 0.6), // opacity-60
        ),
      );
}
