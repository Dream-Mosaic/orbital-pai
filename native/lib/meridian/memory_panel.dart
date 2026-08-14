import 'package:flutter/material.dart';

import '../panels/memory_client.dart';
import '../voice/voice_controller.dart';
import 'hero_icon.dart';
import 'tokens.dart';

/// The Memory drawer's contents — the port of `memory_panel/1` in
/// `lib/app_web/components/voice_modals.ex` (~783-835): the rolling summary
/// textarea, the profile-facts list with its add-fact field, and a
/// destructive wipe control. The web's own two entry points to the same
/// `forget_me` action disagree on their label ("Wipe memory" on the Settings
/// panel, voice_modals.ex:654; "Forget me" on this one, voice_modals.ex:835)
/// — this port uses "Wipe memory" for both, per the design brief, so the one
/// destructive action reads identically everywhere in the native app.
///
/// Server-authoritative: every write pushes and the UI re-renders from the
/// next `state`. The summary field is the one place that needs to resist
/// that — see `_syncSummary`.
class MemoryPanelView extends StatefulWidget {
  const MemoryPanelView({super.key, required this.client});

  final MemoryClient client;

  /// So a test — and this view's own keyboard-avoidance — can find the
  /// add-fact field.
  static const Key addFactKey = ValueKey('memory-add-fact');

  /// Same rationale as [addFactKey], for the summary field.
  static const Key summaryFieldKey = ValueKey('memory-summary');

  @override
  State<MemoryPanelView> createState() => _MemoryPanelViewState();
}

class _MemoryPanelViewState extends State<MemoryPanelView>
    with WidgetsBindingObserver {
  final _summaryCtrl = TextEditingController();
  final _summaryFocus = FocusNode();
  final _addFactCtrl = TextEditingController();
  final _addFactFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _summaryFocus.addListener(() => _revealAboveKeyboard(_summaryFocus));
    _addFactFocus.addListener(() => _revealAboveKeyboard(_addFactFocus));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _summaryCtrl.dispose();
    _summaryFocus.dispose();
    _addFactCtrl.dispose();
    _addFactFocus.dispose();
    super.dispose();
  }

  // A device's keyboard height is not known at the moment focus lands — it
  // animates in afterward — so re-check on every metrics change too, not
  // just on focus.
  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    if (_summaryFocus.hasFocus) _revealAboveKeyboard(_summaryFocus);
    if (_addFactFocus.hasFocus) _revealAboveKeyboard(_addFactFocus);
  }

  /// The drawer's body is a bare `SingleChildScrollView` with no `Scaffold`
  /// above it, so nothing shrinks it for an on-screen keyboard the way
  /// `resizeToAvoidBottomInset` would — the ambient viewport's own bounds
  /// stay full-height regardless of `MediaQuery.viewInsets`, so the built-in
  /// caret-follow scroll never realises the field is covered. Do it by hand:
  /// find how far the focused field's bottom edge sits below the keyboard's
  /// top edge and nudge the ancestor `Scrollable` by that much.
  void _revealAboveKeyboard(FocusNode node) {
    if (!node.hasFocus) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !node.hasFocus) return;
      final renderObject = node.context?.findRenderObject();
      if (renderObject is! RenderBox || !renderObject.attached) return;
      final media = MediaQuery.of(context);
      final bottomInset = media.viewInsets.bottom;
      if (bottomInset <= 0) return;
      final fieldBottom =
          renderObject.localToGlobal(Offset(0, renderObject.size.height)).dy;
      final keyboardTop = media.size.height - bottomInset;
      final overlap = fieldBottom - keyboardTop;
      if (overlap <= 0) return;
      final position = Scrollable.maybeOf(context)?.position;
      if (position == null) return;
      // +48 clears the InputDecorator's own border/padding, which sits
      // outside the FocusNode's (EditableText-only) rect measured above.
      //
      // A jump, not animateTo: focus and the metrics change the keyboard
      // itself causes both re-fire this callback, and a second animateTo
      // arriving before the first one finishes lets its TickerFuture resolve
      // early at whatever offset it had reached — sometimes still the start
      // — so the field would never reliably land clear of the keyboard. A
      // jump commits to the correct position in one step instead of racing
      // an animation against its own re-entry.
      position.jumpTo((position.pixels + overlap + 48)
          .clamp(0.0, position.maxScrollExtent));
    });
  }

  // Seed from the server only when the user is not in the field. Without
  // this, every incoming `state` — including the one caused by the user's
  // own save — would yank the cursor and could discard in-flight edits.
  void _syncSummary(String fromServer) {
    if (_summaryFocus.hasFocus) return;
    if (_summaryCtrl.text == fromServer) return;
    _summaryCtrl.text = fromServer;
  }

  void _save() => widget.client.saveSummary(_summaryCtrl.text);

  void _submitAddFact() {
    final text = _addFactCtrl.text.trim();
    if (text.isEmpty) return;
    widget.client.addFact(text);
    _addFactCtrl.clear();
  }

  Future<void> _wipeMemory(BuildContext context) async {
    const question =
        'Forget everything ${VoiceController.assistantName} knows about you?';
    if (await _confirm(context, question)) widget.client.forgetMe();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: widget.client,
        builder: (context, _) {
          final state = widget.client.state;
          if (state == null) return const SizedBox.shrink();
          _syncSummary(state.summary);
          return Padding(
            // Guarantees there is scroll room below the last field for
            // _revealAboveKeyboard to actually scroll into — without this, a
            // short panel has nowhere further to go and a field near the
            // bottom stays pinned behind the keyboard no matter what.
            padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _summarySection(),
                const SizedBox(height: 16),
                _factsSection(state),
                const SizedBox(height: 16),
                _wipeButton(context),
              ],
            ),
          );
        },
      );

  Widget _summarySection() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _SectionLabel('Rolling summary'),
          const SizedBox(height: 8),
          TextField(
            key: MemoryPanelView.summaryFieldKey,
            controller: _summaryCtrl,
            focusNode: _summaryFocus,
            minLines: 3,
            maxLines: 6,
            style: const TextStyle(fontSize: 14, color: M.ink),
            decoration:
                _fieldDecoration("(nothing yet — we'll build this as we talk)"),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              onPressed: _save,
              style: OutlinedButton.styleFrom(foregroundColor: M.ink),
              child: const Text('Save'),
            ),
          ),
        ],
      );

  Widget _factsSection(MemoryState state) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _SectionLabel('Profile facts'),
          const SizedBox(height: 8),
          if (state.facts.isEmpty)
            Text(
              'No facts yet.',
              style: TextStyle(
                fontSize: 14,
                color: M.ink.withValues(alpha: 0.5),
              ),
            )
          else
            for (final fact in state.facts) _factRow(fact),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: MemoryPanelView.addFactKey,
                  controller: _addFactCtrl,
                  focusNode: _addFactFocus,
                  style: const TextStyle(fontSize: 14, color: M.ink),
                  decoration:
                      _fieldDecoration('Add something I should remember…'),
                  onSubmitted: (_) => _submitAddFact(),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: _submitAddFact,
                style: OutlinedButton.styleFrom(foregroundColor: M.ink),
                child: const Text('Add'),
              ),
            ],
          ),
        ],
      );

  Widget _factRow(MemoryFact fact) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Text(
                fact.content,
                style: const TextStyle(fontSize: 14, color: M.ink),
              ),
            ),
            Tooltip(
              message: 'delete fact',
              child: GestureDetector(
                key: ValueKey('memory-delete-fact-${fact.id}'),
                behavior: HitTestBehavior.opaque,
                onTap: () => widget.client.deleteFact(fact.id),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  child:
                      HeroIconView(HeroIcon.xMark, size: 16, color: M.inkDim),
                ),
              ),
            ),
          ],
        ),
      );

  Widget _wipeButton(BuildContext context) => Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton(
          onPressed: () => _wipeMemory(context),
          style: OutlinedButton.styleFrom(
            foregroundColor: _dangerRed,
            side: BorderSide(color: _dangerRed.withValues(alpha: 0.4)),
          ),
          child: const Text('Wipe memory'),
        ),
      );

  InputDecoration _fieldDecoration(String hint) => InputDecoration(
        isDense: true,
        hintText: hint,
        hintStyle: TextStyle(fontSize: 14, color: M.ink.withValues(alpha: 0.4)),
        filled: true,
        fillColor: M.bg.withValues(alpha: 0.3),
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: M.hairline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: M.hairline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: M.you.withValues(alpha: 0.6)),
        ),
      );
}

/// The web's `#voice-modal .btn-error { color: #f87171 }` red, the same
/// clipped-oklch conversion banked as settings_panel.dart's `_dangerRed` —
/// duplicated here rather than shared because it is `_`-private to that
/// library (see that file's comment for the full derivation).
const Color _dangerRed = Color(0xFFEA003E);

/// Mirrors the web's `data-confirm`, and settings_panel.dart's `_confirm`.
/// Acts only on an explicit true — a dismissed dialog returns null.
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

/// The same 12px / `M.ink` @ 60% recipe as reminders_panel.dart's and
/// settings_panel.dart's own `_SectionLabel` (duplicated for the same
/// library-privacy reason as `_dangerRed` above).
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
