import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'thread_model.dart';
import 'tokens.dart';
import 'voice_md.dart';

/// The transcript "meridian": a glowing spine on the left rail, your amber turns
/// rail-aligned to its left, Henry's green answers in the field to its right, and
/// reflex asides as a hollow node between them. Ported from `#voice .log`,
/// `.spine`, `#voice-log`, `.voice-line` and the `.who-*` rules in app.css.
///
/// TWO rail bases, deliberately. `.spine` is absolutely positioned inside `.log`
/// (which is `relative`), so its `36%` resolves against `.log`'s PADDING box;
/// `.who-you`'s width and `.who-brain`'s margin resolve theirs against
/// `#voice-log`'s CONTENT box, which is 12px narrower. The visible consequence is
/// that the nodes sit a few px clear of the rail rather than centred on it.
/// Collapsing these onto one base would close that gap and quietly restyle the
/// transcript, so both are reproduced.
class Thread extends StatelessWidget {
  const Thread({
    super.key,
    required this.items,
    required this.glow,
    this.scrollController,
    this.onAck,
  });

  final List<ThreadItem> items;

  /// `paletteFor(orbState).glow` — the spine's top stop recolours with the orb.
  final Color glow;

  final ScrollController? scrollController;
  final void Function(int reminderId)? onAck;

  static const double _railFraction = 0.36; // --rail
  static const double _logPadX = 4.0; // #voice .log padding: 0 4px
  static const double _scrollerPadX = 2.0; // #voice-log padding: 16px 2px 10px
  static const double _firstGap = 3.2; // .voice-line:first-child margin-top 0.2rem
  static const double _labelSize = 8.64; // .who 0.54rem
  static const double _bodyTop = 3.52; // .body margin-top 0.22rem

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: _logPadX),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // `.log`'s content box is what LayoutBuilder sees, the padding box is
          // 2*4px wider, and `#voice-log`'s content box is 2*2px narrower.
          final logContent = constraints.maxWidth;
          final railSpine = (logContent + 2 * _logPadX) * _railFraction;
          final railLine = (logContent - 2 * _scrollerPadX) * _railFraction;
          return Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                // CSS measures from `.log`'s border box; this Stack starts one
                // padding in.
                left: railSpine + 8 - _logPadX,
                top: -12,
                bottom: 4,
                width: 1.5,
                child: IgnorePointer(
                  child: _Spine(key: const ValueKey('spine'), glow: glow),
                ),
              ),
              ShaderMask(
                blendMode: BlendMode.dstIn,
                // mask-image: linear-gradient(to bottom, transparent, #000 9%)
                shaderCallback: (rect) => const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x00000000), Color(0xFF000000)],
                  stops: [0.0, 0.09],
                ).createShader(rect),
                child: ListView.builder(
                  controller: scrollController,
                  padding: const EdgeInsets.fromLTRB(
                      _scrollerPadX, 16, _scrollerPadX, 10),
                  itemCount: items.length,
                  itemBuilder: (context, i) => Padding(
                    // Adjacent CSS margins collapse to the larger of the two.
                    padding: EdgeInsets.only(
                      top: i == 0
                          ? _firstGap
                          : math.max(items[i - 1].margin, items[i].margin),
                    ),
                    child: KeyedSubtree(
                      key: ValueKey('item-$i'),
                      child: _item(items[i], railLine),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _item(ThreadItem item, double rail) => switch (item) {
        ThreadDivider() => Center(
            child: Text(
              '— earlier —',
              style: TextStyle(
                fontSize: 11.2, // 0.7rem
                color: M.ink.withValues(alpha: 0.4),
              ),
            ),
          ),
        ThreadMetrics() => Text(
            item.text,
            style: TextStyle(
              fontSize: 10.4, // 0.65rem
              color: M.ink.withValues(alpha: 0.45),
            ),
          ),
        ThreadToolChip() => Text(
            item.text,
            style: TextStyle(
              fontSize: 12, // 0.75rem
              fontStyle: FontStyle.italic,
              color: M.ink.withValues(alpha: 0.55),
            ),
          ),
        ThreadLine() =>
          item.kind == LineKind.you ? _youLine(item, rail) : _fieldLine(item, rail),
      };

  // --- `you`: amber, right-aligned on the rail to the spine's left ---
  Widget _youLine(ThreadLine line, double rail) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        SizedBox(
          width: rail - 18, // .who-you width: calc(var(--rail) - 18px)
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(line.label.toLowerCase(), style: _labelStyle(M.you)),
              const SizedBox(height: _bodyTop),
              Text(
                line.text,
                textAlign: TextAlign.right,
                style: _bodyStyle(13.44, M.youBody), // 0.84rem
              ),
            ],
          ),
        ),
        // ::before right: -22px, i.e. the dot's right edge sits 22px past the
        // block's right edge (rail - 18), so its left edge is at rail - 3.
        Positioned(
          left: rail - 3,
          top: _labelSize * 0.32,
          child: const _Dot(key: ValueKey('node'), fill: M.you),
        ),
      ],
    );
  }

  // --- Henry's answers, reflex asides, and the agenda leads: the field ---
  Widget _fieldLine(ThreadLine line, double rail) {
    final (labelColour, bodySize, bodyColour, italic, dot) = switch (line.kind) {
      LineKind.brain => (M.henry, 14.88, M.brainBody, false, const _Dot(key: ValueKey('node'), fill: M.henry)),
      LineKind.reflex => (
          M.chromeDim.withValues(alpha: 0.34),
          12.8, // .who-reflex .body 0.8rem
          M.chromeDim.withValues(alpha: 0.42),
          true,
          const _Dot(key: ValueKey('node'), border: true),
        ),
      LineKind.briefing => (M.briefing, 14.88, M.brainBody, false, const _Dot(key: ValueKey('node'), fill: M.briefing)),
      LineKind.followup => (M.followup, 14.88, M.brainBody, false, const _Dot(key: ValueKey('node'), fill: M.followup)),
      // The CSS has NO `.who-reminder` rule, so the web renders reminders with no
      // rail offset, no dot and an inherited label colour. That is a web gap, not
      // a design; the port gives them the brain geometry in the `--you` accent
      // they already carry via the Ack chip. See spec §4.4 — the one deliberate
      // thread deviation.
      LineKind.reminder => (M.you, 14.88, M.brainBody, false, const _Dot(key: ValueKey('node'), fill: M.you)),
      LineKind.you => (M.you, 13.44, M.youBody, false, const _Dot(key: ValueKey('node'), fill: M.you)),
    };

    final reflex = line.kind == LineKind.reflex;
    final body = line.thinking
        ? Text(
            line.text,
            style:
                _bodyStyle(bodySize, M.chromeDim.withValues(alpha: 0.42), italic: true),
          )
        : line.markdown
            ? VoiceMarkdown(text: line.text, baseStyle: _bodyStyle(bodySize, bodyColour))
            : Text(line.text, style: _bodyStyle(bodySize, bodyColour, italic: italic));

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Padding(
          padding: EdgeInsets.only(left: rail + 18), // margin-left: calc(rail + 18px)
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(line.label.toLowerCase(), style: _labelStyle(labelColour)),
              SizedBox(height: reflex ? 1.6 : _bodyTop), // .who-reflex .body 0.1rem
              body,
              if (line.ack != AckState.none) _ackChip(line),
            ],
          ),
        ),
        // ::before left: -22px (reflex: -21.5px), relative to the rail+18 margin.
        Positioned(
          left: reflex ? rail - 3.5 : rail - 4,
          top: _labelSize * (reflex ? 0.38 : 0.32),
          child: dot,
        ),
      ],
    );
  }

  Widget _ackChip(ThreadLine line) {
    final acked = line.ack == AckState.acked;
    return Padding(
      padding: const EdgeInsets.only(top: 7.2), // .ack-chip margin-top 0.45rem
      child: GestureDetector(
        onTap: acked || line.ackId == null ? null : () => onAck?.call(line.ackId!),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 13.6, vertical: 5.6),
          decoration: BoxDecoration(
            color: acked ? Colors.transparent : M.you.withValues(alpha: 0.12),
            border: Border.all(
              color: acked
                  ? M.chromeDim.withValues(alpha: 0.25)
                  : M.you.withValues(alpha: 0.45),
            ),
            borderRadius: BorderRadius.circular(999),
          ),
          // .ack-chip is text-transform: lowercase, so the DOM's "Ack"/"Acked ✓"
          // render lowercase — same treatment as the .who speaker labels.
          child: Text(
            acked ? 'acked ✓' : 'ack',
            style: TextStyle(
              fontSize: 9.92, // 0.62rem
              fontWeight: FontWeight.w600, // CSS 650; Flutter has no w650
              letterSpacing: MType.track(9.92, 0.18),
              color: acked ? M.chromeDim.withValues(alpha: 0.5) : M.you,
            ),
          ),
        ),
      ),
    );
  }

  static TextStyle _labelStyle(Color colour) => TextStyle(
        fontFamily: kDisplayFamily,
        fontSize: _labelSize,
        fontWeight: FontWeight.w600, // CSS 650
        letterSpacing: MType.track(_labelSize, 0.24),
        color: colour,
      );

  static TextStyle _bodyStyle(double size, Color colour, {bool italic = false}) =>
      TextStyle(
        fontFamily: kBodyFamily,
        fontSize: size,
        height: 1.5, // .body line-height
        color: colour,
        fontStyle: italic ? FontStyle.italic : null,
      );
}

/// 7x7 filled node (or the reflex's 6x6 hollow one) on the spine.
class _Dot extends StatelessWidget {
  const _Dot({super.key, this.fill, this.border = false});

  final Color? fill;
  final bool border;

  @override
  Widget build(BuildContext context) {
    if (border) {
      return Container(
        width: 6,
        height: 6,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: M.chromeDim.withValues(alpha: 0.35)),
        ),
      );
    }
    final colour = fill!;
    return Container(
      width: 7,
      height: 7,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: colour,
        boxShadow: [BoxShadow(color: colour.withValues(alpha: 0.8), blurRadius: 9)],
      ),
    );
  }
}

/// The glowing rail. A decorative SIBLING of the scroller, not a child, so it
/// stays put while the transcript scrolls past it.
class _Spine extends StatelessWidget {
  const _Spine({super.key, required this.glow});

  final Color glow;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            glow.withValues(alpha: 0.65),
            const Color(0x17FFFFFF), // rgba(255,255,255,0.09)
            const Color(0x17FFFFFF),
            const Color(0x00FFFFFF),
          ],
          stops: const [0.0, 0.30, 0.88, 1.0],
        ),
      ),
    );
  }
}
