import 'package:flutter/material.dart';

import '../panels/voice_lock_client.dart';
import 'tokens.dart';

/// Copied byte-for-byte from `@voice_lock_prompts`
/// (server/lib/app_web/components/voice_modals.ex:684-691). These are
/// CALIBRATION INPUTS: reading a different sentence than the one enrolled
/// quietly degrades the voiceprint, so do not "tidy" the punctuation. The
/// apostrophes here are plain ASCII (0x27), verified with a Unicode dump.
const List<(int, String)> kVoiceLockPrompts = [
  (
    1,
    "Hey Remi, this is my normal speaking voice. I'm going to ask about the weather, my calendar, reminders, and the grocery list, just like I do every day."
  ),
  (
    2,
    'The quick brown fox jumps over the lazy dog, while the five boxing wizards jump quickly over the frozen river behind our house.'
  ),
  (
    3,
    "What's on my calendar tomorrow morning? Remind me to water the garden at six, and add milk, eggs, and coffee to the groceries, please."
  ),
];

/// `~w(off shadow enforce)` — the segmented control's order, and the literal
/// string this panel sends to `set_mode`.
const List<String> _kModes = ['off', 'shadow', 'enforce'];

/// daisyUI's dark `--color-warning`, `oklch(66% 0.179 58.318)` (app.css:48)
/// — the SAME clipped-oklch conversion method that reproduces M.success
/// (#009689, tokens.dart) and `_dangerRed` below exactly from their own
/// oklch triples, so it is trustworthy here too. Used for `recording…`
/// (`text-warning`) and the model-unavailable banner (`alert-warning`).
const Color _warning = Color(0xFFDF6F00);

/// The web's `#voice-modal .btn-error { color: #f87171 }` red — the same
/// clipped-oklch conversion already banked as memory_panel.dart's /
/// settings_panel.dart's own `_dangerRed` (private to each library, hence
/// duplicated here too; see those files for the full derivation).
const Color _dangerRed = Color(0xFFEA003E);

/// The Voice Lock drawer's contents — the port of `voice_lock_panel/1` in
/// `lib/app_web/components/voice_modals.ex` (~699-772): a tri-state mode
/// selector, guided three-prompt enrollment, and a "Recently filtered" audit
/// list, with a model-unavailable banner above everything else when the
/// speaker model failed to load.
///
/// Server-authoritative for `mode`, `enrolled_slots`, `verifier_ready` and
/// `drops`; [VoiceLockClient.recordingSlot] and [VoiceLockClient.enrollError]
/// are CLIENT-LOCAL UI state, exactly as they are `prev`-preserved LiveView
/// assigns on the web, and are not on the wire. Per spec §9's last row,
/// enrollment stays available even when the banner is up — the embed just
/// fails server-side and says so; the UI does not gate on `verifier_ready`.
class VoiceLockPanelView extends StatelessWidget {
  const VoiceLockPanelView({super.key, required this.client});

  final VoiceLockClient client;

  /// So a test can tap one mode without matching on its shared label text.
  static Key modeKey(String mode) => ValueKey('voice-lock-mode-$mode');

  /// So a test can tap one slot's Record button; all three share a label.
  static Key recordKey(int slot) => ValueKey('voice-lock-record-$slot');

  /// One prompt card's own key, so a test can scope a `find.text` to just
  /// that slot's row (e.g. "recording…" must show against slot 2 only, not
  /// slot 1 or 3). Not part of the brief's required interface, but built the
  /// same deterministic way so a test can reconstruct it directly.
  static Key slotKey(int slot) => ValueKey('voice-lock-slot-$slot');

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
              if (!state.verifierReady) ...[
                _banner(),
                const SizedBox(height: 16), // space-y-4
              ],
              _modeSection(state),
              const SizedBox(height: 16),
              _enrollmentSection(state),
              const SizedBox(height: 16),
              _dropsSection(state),
            ],
          );
        },
      );

  Widget _banner() => Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: _warning.withValues(alpha: 0.12),
          border: Border.all(color: _warning.withValues(alpha: 0.4)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Text(
          'Speaker model unavailable — Voice Lock is failing open '
          '(everything passes).',
          style: TextStyle(fontSize: 14, color: _warning),
        ),
      );

  Widget _modeSection(VoiceLockState state) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _SectionLabel('Mode'),
          const SizedBox(height: 8), // space-y-2
          Row(
            children: [
              for (final mode in _kModes) ...[
                Expanded(child: _modeButton(state, mode)),
                if (mode != _kModes.last) const SizedBox(width: 4),
              ],
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'Shadow scores every turn but blocks nothing — live with it a '
            'few days, then enforce.',
            style: TextStyle(fontSize: 12, color: M.inkDim),
          ),
        ],
      );

  Widget _modeButton(VoiceLockState state, String mode) {
    final selected = state.mode == mode;
    return GestureDetector(
      key: VoiceLockPanelView.modeKey(mode),
      behavior: HitTestBehavior.opaque,
      onTap: () => client.setMode(mode),
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
          color:
              selected ? M.you.withValues(alpha: 0.18) : Colors.transparent,
          border: Border.all(
            color:
                selected ? M.you.withValues(alpha: 0.55) : Colors.transparent,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          _capitalize(mode),
          style: TextStyle(
            fontSize: 12,
            fontFamily: kDisplayFamily,
            fontWeight: FontWeight.w600,
            color: selected ? M.youSoft : M.inkDim,
          ),
        ),
      ),
    );
  }

  Widget _enrollmentSection(VoiceLockState state) {
    // The web's `disabled={@vl.recording_slot != nil}` — ALL THREE Record
    // buttons disable while ANY slot is recording, not just the one that is.
    final anyRecording = client.recordingSlot != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionLabel(
            'Enrollment — read each prompt aloud (~10s each)'),
        const SizedBox(height: 8),
        for (final (slot, text) in kVoiceLockPrompts) ...[
          _promptCard(state, slot, text, anyRecording),
          if (slot != kVoiceLockPrompts.last.$1) const SizedBox(height: 8),
        ],
      ],
    );
  }

  Widget _promptCard(
      VoiceLockState state, int slot, String text, bool anyRecording) {
    final enrolled = state.enrolledSlots.contains(slot);
    final recording = client.recordingSlot == slot;
    final error = client.enrollError;
    final errorText = (error != null && error.$1 == slot) ? error.$2 : null;
    return Container(
      key: VoiceLockPanelView.slotKey(slot),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: M.hairline),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(text, style: const TextStyle(fontSize: 14, color: M.ink)),
          const SizedBox(height: 8),
          Row(
            children: [
              _recordButton(slot, enrolled, anyRecording),
              const SizedBox(width: 8),
              if (recording)
                const Text('recording…',
                    style: TextStyle(fontSize: 12, color: _warning))
              else if (enrolled)
                const Text('✓ enrolled',
                    style: TextStyle(fontSize: 12, color: M.success)),
              if (errorText != null) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    errorText,
                    style: const TextStyle(fontSize: 12, color: _dangerRed),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  /// `disabled` is `client.recordingSlot != null` for every slot — the same
  /// value regardless of WHICH slot this button belongs to — so a slot's own
  /// button disables too while it is the one recording (the web disables via
  /// a single top-level `disabled={@vl.recording_slot != nil}`, not a
  /// per-button `!= slot` comparison).
  Widget _recordButton(int slot, bool enrolled, bool disabled) {
    final button = GestureDetector(
      key: VoiceLockPanelView.recordKey(slot),
      behavior: HitTestBehavior.opaque,
      onTap: disabled ? null : () => client.startRecording(slot),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: disabled ? const Color(0x08FFFFFF) : Colors.transparent,
          border: Border.all(color: M.hairline),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          enrolled ? 'Re-record' : 'Record',
          style: TextStyle(
            fontSize: 11,
            fontFamily: kDisplayFamily,
            fontWeight: FontWeight.w600,
            color: disabled ? M.inkFaint : M.inkDim,
          ),
        ),
      ),
    );
    return disabled ? Opacity(opacity: 0.35, child: button) : button;
  }

  Widget _dropsSection(VoiceLockState state) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _SectionLabel('Recently filtered'),
          const SizedBox(height: 8),
          if (state.drops.isEmpty)
            Text(
              'Nothing filtered yet.',
              style: TextStyle(
                  fontSize: 12, color: M.ink.withValues(alpha: 0.5)),
            )
          else
            for (final drop in state.drops) _dropRow(drop),
        ],
      );

  Widget _dropRow(GateDrop drop) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            _dropBadge(drop.decision),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                drop.transcript,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 12, color: M.ink.withValues(alpha: 0.8)),
              ),
            ),
            // The web's `{e.score && Float.round(e.score, 2)}`
            // (voice_modals.ex:768) — nullable on the wire, rendered
            // conditionally. Do NOT coerce a null score to 0.00, which would
            // read as a confident score on the panel people read scores off
            // during calibration.
            if (drop.score != null) ...[
              const SizedBox(width: 8),
              Text(drop.score!.toStringAsFixed(2),
                  style: TextStyle(
                      fontSize: 12,
                      fontFamily: 'monospace',
                      color: M.ink.withValues(alpha: 0.6))),
            ],
          ],
        ),
      );

  Widget _dropBadge(String decision) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: const Color(0x05FFFFFF),
          borderRadius: BorderRadius.circular(999),
        ),
        child:
            Text(decision, style: const TextStyle(fontSize: 10, color: M.inkFaint)),
      );
}

String _capitalize(String s) =>
    s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

/// The same 12px / `M.ink` @ 60% recipe as reminders_panel.dart's /
/// settings_panel.dart's / memory_panel.dart's own `_SectionLabel`
/// (duplicated for the same library-privacy reason as `_dangerRed` above).
class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: TextStyle(
          fontSize: 12, // text-xs
          color: M.ink.withValues(alpha: 0.6), // opacity-60
        ),
      );
}
