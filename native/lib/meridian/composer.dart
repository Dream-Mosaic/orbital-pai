import 'package:flutter/material.dart';
import 'hero_icon.dart';
import 'hold_to_talk.dart';
import 'tokens.dart';

/// Type to Henry (spec 2026-10-10 household wave 1, F1).
///
/// The hold-to-talk tray with a keyboard key engraved beside it. Tapping the key
/// swaps the tray for a composer — the same machined glass, now holding a text
/// field — and the mic key at its left swaps back. A typed message is a quiet
/// turn: the server answers it in text and never speaks, so this is how you
/// talk to Henry in a meeting, on a loud train, or next to someone asleep.
///
/// It is deliberately independent of every voice mode: it works with PTT off,
/// while the conversation is wake-locked, and while Henry is mid-answer (the
/// server treats a typed message as a barge-in).
///
/// [onSend] gets the trimmed, non-blank text and says whether it left the
/// device; a refused send keeps the draft. Nothing is drawn optimistically —
/// the server's `transcript` echo adds the "you" line.
class ComposerDock extends StatefulWidget {
  const ComposerDock({
    super.key,
    required this.pttEnabled,
    required this.pttHeld,
    required this.onPttPress,
    required this.onPttRelease,
    required this.onSend,
  });

  final bool pttEnabled;
  final bool pttHeld;
  final VoidCallback onPttPress;
  final VoidCallback onPttRelease;
  final bool Function(String text) onSend;

  static const Key keyboardKey = ValueKey('composer-open');
  static const Key micKey = ValueKey('composer-close');
  static const Key sendKey = ValueKey('composer-send');
  static const Key fieldKey = ValueKey('composer-field');

  @override
  State<ComposerDock> createState() => _ComposerDockState();
}

class _ComposerDockState extends State<ComposerDock> {
  final TextEditingController _text = TextEditingController();
  final FocusNode _focus = FocusNode(debugLabel: 'composer');
  bool _composing = false;

  @override
  void initState() {
    super.initState();
    // The send key lights up only once there is something to send.
    _text.addListener(_onTextChanged);
    _focus.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _text.removeListener(_onTextChanged);
    _focus.removeListener(_onTextChanged);
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    if (mounted) setState(() {});
  }

  void _open() {
    setState(() => _composing = true);
    // The field mounts this frame; focus it the moment it exists so the soft
    // keyboard comes up with the composer, not a tap later.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _composing) _focus.requestFocus();
    });
  }

  void _close() {
    _focus.unfocus();
    // The draft is kept: swapping to the mic and back should not eat it.
    setState(() => _composing = false);
  }

  void _submit() {
    final message = _text.text.trim();
    if (message.isNotEmpty && widget.onSend(message)) _text.clear();
    // Stay in the field for the follow-up — the keyboard's send action would
    // otherwise take the focus (and the keyboard) away with it.
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      child: _composing ? _composer() : _tray(),
    );
  }

  Widget _tray() => IntrinsicHeight(
        key: const ValueKey('tray'),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: HoldToTalkBar(
                enabled: widget.pttEnabled,
                held: widget.pttHeld,
                onPress: widget.onPttPress,
                onRelease: widget.onPttRelease,
              ),
            ),
            const SizedBox(width: 8),
            _GlassKey(
              key: ComposerDock.keyboardKey,
              icon: HeroIcon.chatBubbleBottomCenterText,
              tooltip: 'Type to Henry',
              onTap: _open,
              framed: true,
            ),
          ],
        ),
      );

  Widget _composer() {
    final focused = _focus.hasFocus;
    final hasText = _text.text.trim().isNotEmpty;
    return AnimatedContainer(
      key: const ValueKey('composer'),
      duration: const Duration(milliseconds: 200),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      decoration: BoxDecoration(
        // Same machined glass as the hold tray, so the swap reads as the tray
        // changing what it holds rather than as a different control arriving.
        color:
            const Color(0xFFFFFFFF).withValues(alpha: focused ? 0.028 : 0.016),
        borderRadius: BorderRadius.circular(14),
        // Focus is an amber EDGE only. A glow would be a BoxShadow, and Flutter
        // paints those under the box — through this translucent glass — so it
        // tints the whole well brown instead of lighting the rim the way the
        // CSS box-shadow it imitates would.
        border: Border.all(
          color: focused
              ? M.you.withValues(alpha: 0.34)
              : const Color(0xFFFFFFFF).withValues(alpha: 0.055),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          _GlassKey(
            key: ComposerDock.micKey,
            icon: HeroIcon.microphone,
            tooltip: 'Back to voice',
            onTap: _close,
          ),
          Expanded(child: _field()),
          _GlassKey(
            key: ComposerDock.sendKey,
            icon: HeroIcon.paperAirplane,
            tooltip: 'Send',
            onTap: _submit,
            lit: hasText,
          ),
        ],
      ),
    );
  }

  Widget _field() => Theme(
        data: Theme.of(context).copyWith(
          textSelectionTheme: TextSelectionThemeData(
            cursorColor: M.you,
            selectionColor: M.you.withValues(alpha: 0.28),
            selectionHandleColor: M.you,
          ),
        ),
        child: TextField(
          key: ComposerDock.fieldKey,
          controller: _text,
          focusNode: _focus,
          minLines: 1,
          maxLines: 4,
          // A plain text keyboard, so its action key is SEND rather than a
          // newline: lines still wrap, they are just never typed.
          keyboardType: TextInputType.text,
          textInputAction: TextInputAction.send,
          textCapitalization: TextCapitalization.sentences,
          onSubmitted: (_) => _submit(),
          // Supplying this is what stops the send action from unfocusing.
          onEditingComplete: () {},
          cursorColor: M.you,
          cursorWidth: 1.6,
          style: const TextStyle(
            fontFamily: kBodyFamily,
            fontSize: 14.4,
            height: 1.4,
            // Your words, in the thread's colour for your words.
            color: M.youBody,
          ),
          decoration: InputDecoration(
            isDense: true,
            border: InputBorder.none,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
            hintText: 'Message Henry…',
            hintStyle: TextStyle(
              fontFamily: kBodyFamily,
              fontSize: 14.4,
              height: 1.4,
              color: M.chromeDim.withValues(alpha: 0.3),
            ),
          ),
        ),
      );
}

/// A square engraved key: the tray's keyboard key, and the composer's mic and
/// send keys. [framed] gives it its own glass (beside the tray); inside the
/// composer it sits bare on the composer's glass. [lit] tints the icon with the
/// "you" amber and its glow — the send key, once there is something to send.
class _GlassKey extends StatelessWidget {
  const _GlassKey({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.framed = false,
    this.lit = false,
  });

  final HeroIcon icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool framed;
  final bool lit;

  static const double _size = 40;

  @override
  Widget build(BuildContext context) {
    final iconColour =
        lit ? M.you : M.chromeDim.withValues(alpha: framed ? 0.42 : 0.38);
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          width: framed ? 46 : _size,
          height: framed ? null : _size,
          alignment: Alignment.center,
          decoration: framed
              ? BoxDecoration(
                  color: const Color(0xFFFFFFFF).withValues(alpha: 0.016),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: const Color(0xFFFFFFFF).withValues(alpha: 0.055),
                  ),
                )
              : null,
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                if (lit)
                  BoxShadow(
                    color: M.you.withValues(alpha: 0.45),
                    blurRadius: 14,
                    spreadRadius: -4,
                  ),
              ],
            ),
            child: HeroIconView(icon, size: 18, color: iconColour),
          ),
        ),
      ),
    );
  }
}
