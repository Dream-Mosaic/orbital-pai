import 'dart:async';

import 'package:flutter/foundation.dart';

import '../audio/mic_capture.dart';

/// Everything [VoiceController] knows about the microphone, as ONE immutable
/// value.
///
/// **INVARIANT A, made structural.** Six Criticals of one class all reduce to
/// the same sentence: *a state flag is written on the far side of an unbounded
/// platform `await`, so a wedged or throwing platform call leaves the state
/// machine lying about the hardware.* Each fix corrected one ordering and
/// exposed its mirror image, because the state lived in eight separate fields
/// and "the transition" was a convention about the order you assigned them in.
///
/// Two things here remove that possibility rather than guarding against it:
///
/// 1. **One field, whole-value writes.** The controller holds a single
///    `MicState`, and a transition is a single synchronous assignment. There
///    is no way to apply half of one, so there is nothing for an `await` to
///    land in the middle of. Fields are `final` and the constructor is
///    private to this library, so the only reachable states are the ones the
///    named transitions below produce.
/// 2. **"On" is not a flag.** [on] is *derived*: the microphone is on if and
///    only if the conversation is subscribed to a session it holds. The sixth
///    Critical was `micOn == true` with the subscription and session already
///    dropped — a sentence this type cannot express.
///
/// The asserts are the third line: they fail the test suite if a future edit
/// inside this library produces a state that claims something impossible.
@immutable
class MicState {
  const MicState._({
    this.session,
    this.sub,
    this.wanted = false,
    this.loaned = false,
    this.loan,
    this.resumeWanted = false,
    this.wasOn = false,
  })  : assert(sub == null || session != null,
            'a microphone cannot be streaming into a session we do not hold'),
        // ^ now also carried by [listening]'s SIGNATURE, which is the only
        //   transition that can produce a non-null `sub`. Kept as well because
        //   an assert is free and a future transition might not be.
        assert(!loaned || (session == null && sub == null && !wanted),
            'a loan means the conversation is holding nothing'),
        assert(loan == null || loaned,
            'a borrowed session can only exist inside a loan');

  /// Nothing claimed, nothing wanted, nothing on loan.
  static const MicState idle = MicState._();

  /// The conversation's own recording session, from the instant [startMic]
  /// ASKS for it rather than from the instant the platform answers. Every
  /// teardown path stops THIS session by name; none of them may stop "the
  /// recorder", because by then it may belong to somebody else.
  final MicSession? session;

  /// The subscription delivering [session]'s frames. Non-null exactly when
  /// the microphone is [on].
  final StreamSubscription<Uint8List>? sub;

  /// Intent: the conversation asked for the microphone. True from the moment
  /// [startMic] claims a session until something takes it away — it differs
  /// from [on] exactly inside the platform's own opening window.
  final bool wanted;

  /// True between `suspendMic()` and `resumeMic()`: the conversation is not
  /// holding the recorder, somebody else is.
  final bool loaned;

  /// The borrowed session, from the instant `suspendMic()` ASKS for it. Held
  /// so `resumeMic()` can stop that specific session instead of "whatever the
  /// recorder is doing" — the difference between closing the loan and
  /// deafening the conversation that already got the mic back.
  final MicSession? loan;

  /// Whether `resumeMic()` should switch the conversation's mic back on.
  /// Captured at suspend time and kept current by start/stopMic DURING the
  /// loan, so a power tap made while enrolling is honoured when the mic comes
  /// back rather than silently lost.
  final bool resumeWanted;

  /// Set when a channel death tears a LIVE mic down, so a successful rejoin
  /// can restore it. Deliberately separate from [wanted]: a user's explicit
  /// `stopMic()` clears this too, so a mic switched off mid-outage is never
  /// resurrected by a later reconnect.
  final bool wasOn;

  /// The microphone is on if and only if we are subscribed to a session we
  /// hold. NOT a stored flag — see the class doc.
  bool get on => sub != null;

  /// A session has been claimed and the platform is opening it.
  MicState opening(MicSession session) {
    assert(!loaned, 'the recorder is on loan; record the intent instead');
    return MicState._(
      session: session,
      wanted: true,
      resumeWanted: resumeWanted,
      wasOn: wasOn,
    );
  }

  /// The platform answered and we are subscribed: the microphone is ON. There
  /// is no separate flag to set, and therefore none to forget.
  ///
  /// [opened] is a REQUIRED, non-nullable argument rather than being read off
  /// `this`, and that is the point: the sixth Critical's state —
  /// `sub != null` with `session == null`, a microphone reporting ON with the
  /// handles to stop it already gone — is not constructible through this
  /// signature. Before, `MicState.idle.listening(sub)` compiled and produced
  /// exactly that; only the debug-only assert above stopped it, and asserts
  /// are compiled out of a release build (MEASURED: the probe compiled and
  /// threw only an `AssertionError`).
  ///
  /// The caller must still check that [opened] is the session the state names
  /// — the assert below says so — because writing a STALE session in would be
  /// a different bug. What the type removes is the silent one: whatever
  /// happens, the microphone cannot claim to be on with nothing to turn off.
  MicState listening(MicSession opened, StreamSubscription<Uint8List> sub) {
    assert(identical(session, opened),
        'the session that opened is not the one this state holds');
    return MicState._(
      session: opened,
      sub: sub,
      wanted: wanted,
      resumeWanted: resumeWanted,
      wasOn: wasOn,
    );
  }

  /// The conversation is holding no recording session. Intents (a pending
  /// restore, an outstanding loan) are deliberately preserved: this says what
  /// the conversation HAS, not what anybody WANTS.
  MicState captureOff() => MicState._(
        loaned: loaned,
        loan: loan,
        resumeWanted: resumeWanted,
        wasOn: wasOn,
      );

  /// The loan begins: the conversation gives up everything it holds in the
  /// same breath, and records whether it should get the microphone back.
  MicState lentOut({required bool restore}) => MicState._(
        loaned: true,
        resumeWanted: restore,
        wasOn: wasOn,
      );

  /// The borrowed session is named — before the platform answers, so a
  /// caller that gives up can still close exactly this one.
  MicState borrowed(MicSession loan) {
    assert(loaned, 'nothing can be borrowed outside a loan');
    return MicState._(
      loaned: true,
      loan: loan,
      resumeWanted: resumeWanted,
      wasOn: wasOn,
    );
  }

  /// The loan is over. Whether the microphone comes back is [resumeWanted]'s
  /// business, and is deliberately still pending here.
  MicState returnedFromLoan() => MicState._(
        resumeWanted: resumeWanted,
        wasOn: wasOn,
      );

  MicState withResumeWanted(bool value) => MicState._(
        session: session,
        sub: sub,
        wanted: wanted,
        loaned: loaned,
        loan: loan,
        resumeWanted: value,
        wasOn: wasOn,
      );

  MicState withWasOn(bool value) => MicState._(
        session: session,
        sub: sub,
        wanted: wanted,
        loaned: loaned,
        loan: loan,
        resumeWanted: resumeWanted,
        wasOn: value,
      );

  @override
  String toString() => 'MicState(on: $on, wanted: $wanted, loaned: $loaned, '
      'resumeWanted: $resumeWanted, wasOn: $wasOn)';
}
