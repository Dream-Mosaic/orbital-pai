# Natural thinking fillers: the reflex, rethought (#49)

**Status:** proposed. This is a design only, with no code. It needs David's approval before a plan is written.
**Issue:** #49, "Use natural audio fillers and pauses for thinking reflex instead of verbal
acknowledgments".

> Replace rigid verbal acknowledgment reflexes (e.g., echoing actions or saying 'got it') with
> natural conversational fillers, subtle thinking sounds, and natural pauses while processing.

## What happens today

**The reflex** is the clip Henry speaks the moment a voice turn ends
(`Conversation` `:generate_reflex` → `spawn_reflex_model` → `spawn_reflex_tts`):

1. A Gemini call (`gemini-3.6-flash` @ `minimal`, 24 output tokens) with `Gemini.reflex_prompt/1`:
   *"your instant first beat … at most 4 words … don't answer … Improvise; don't copy: "On it—",
   "Hm.", "Sure—", "Right—", "Noted.", "Oh?", "Lovely."."* Ink's `turn.eager_end` can start this
   call early (`eager_reflex`, the speculative reflex).
2. The text goes through Cartesia's batch HTTP synth as one clip, pushed as `:reflex` audio. It
   also becomes a `speak_start` with source `reflex`, which the app shows as a hollow aside in
   the thread.
3. The brain's audio, captions and cards are **held behind it** (`reflex_mode: :always`), and the
   gate opens on `:reflex_sent`. A `:race` mode exists, where brain audio that lands first skips
   the reflex, but it was never switched on.
4. If the model call fails, Henry says `"Hm, go on?"` (`reflex_fallback/1`).

**Tool bridges** are canned per-tool phrases spoken through the brain's own Cartesia context when
a tool round starts (`Tool.bridge/1`, `Gemini.bridge_phrase/2`). Examples are `"On it."`,
`"Doing that now."`, `"Sending that now."` and `"Checking your calendar, one moment."`.

**What production says.** Source: SigNoz, `personal-assistant`, every `[turn] metrics` line it
still holds (2026-10-25 → 2026-11-03; 46 reflex turns, 54 with brain audio):

| | p10 | p25 | p50 | p75 | p90 |
|---|---|---|---|---|---|
| `ttfa` (reflex audio out) | 0.28 s | 0.48 s | 0.96 s | 1.17 s | 1.73 s |
| `ttb` (first brain audio, bridge included) | 1.1 s | 4.1 s | 6.4 s | 10.2 s | 14.1 s |
| gap, reflex → first brain audio | 2.5 s | 3.5 s | 6.3 s | 9.5 s | 14.7 s |

On the eager path, Cartesia's batch synth of the reflex takes **~230–280 ms**: the gap between
`reflex (eager head-start)` and its `metrics` line. The model call is what spreads `ttfa`, with
outliers at 2.4 s, 3.0 s and 4.6 s. Tool-less turns are slow too: on 2026-11-03 a `round: 0
calls, 189 chars` answer took 10.5 s to its first audio, which is the brain at `medium` thinking.

**So the issue is really four problems:**

1. **The beat is an acknowledgment by design.** Five of the seven examples in the prompt are
   acks, and a 24-token model told to make "the quick sound you make" lands on "Got it" or an echo
   of the request ("Turning it off—"). This has happened even though "Hm." is in the list.
2. **It is followed by silence.** A typical turn is a half-second "On it—", then **~6 s of nothing**,
   and the 1-in-10 case is 15 s. The issue's "while processing" asks for exactly this gap to be
   filled.
3. **Acknowledgments double up.** A home turn can say "On it—" (the reflex) and then "On it." (the
   `home_control` bridge).
4. **It costs a model call on every turn.** That is 0.25–4.6 s of variance, plus a fallback
   (`"Hm, go on?"`) that sounds like Henry asking the user to keep talking.

## Goals

- Henry's first sound reads as **someone thinking, not someone confirming**: no "got it", no
  "noted", and no echo of the action.
- **Natural pauses are allowed**, but dead air while the brain works is not. Space out a few quiet
  thinking sounds, and stop the moment there is a real answer.
- **No added latency to the answer**, no new provider and no new env var. Ideally `ttfa` gets
  steadier.
- **Nothing in the thread that isn't content.** A "Hmm." is not something you want to scroll
  back to.

## Non-goals

- The brain's answer style and prompt.
- The brain's latency. Fillers mask the ~6 s `ttb`; they don't cut it. That is worth its own issue
  (e.g. the `medium` thinking level, or the latency-pack `tts_max_buffer_delay_ms` side-quest).
- Bare-wake acks (`@acks`: "Yeah?", "Hm?", "Mm?", "Go on.") are already natural.
- Agenda leads (`lead_for/2`) and canned agenda items: they carry content.
- Typed turns. They are quiet and have no reflex; that stays as it is.
- Device-side earcons or non-speech sounds (see *Alternatives*).

## Design

### 1. A filler bank replaces the reflex model call

New pure module **`App.Conversations.Fillers`** (shape follows `Backchannel`/`WakeWord`: data and
pure functions, `@doc false def` helpers, no I/O):

- `shape(transcript) :: :ask | :remark` checks whether the utterance is a question or request, or
  just a remark. The rule is cheap: a `?`, or a leading question, auxiliary or imperative word
  (`what how when where who why is are do does can could would will should set turn add remind
  tell play send start find check …`), means `:ask`. Anything else is `:remark`. A wrong guess
  costs little, because the remark set is made of neutral sounds.
- `pick(shape, slot, recent) :: {id, text} | :silence`. `slot` is `:beat` (the first sound) or
  `:thinking` (the cadence, see §3). `recent` holds the last few ids, so the same sound is not
  played twice in a row across turns. The Conversation keeps that list.

The proposed bank is below. **The wording is David's call (open question 1).** It lives in one
module, so editing it is a one-line change.

| slot | shape | entries |
|---|---|---|
| `:beat` | `:ask` | "Hmm." · "Hm—" · "Mm…" · "Let's see…" · "Okay…" · "Hmm, okay…" · "Right, um…" · "Uh, let's see." |
| `:beat` | `:remark` | "Mm." · "Hm." · "Ah." · "Huh." · "Mm-hm." |
| `:thinking` | any | "Mm…" · "Hmm…" · "Let's see…" · "Uh…" · "Hang on…" · "One sec…" · "Bear with me…" |

**Bank rules**, each one pinned by a test over the whole bank:

- Each entry is at most 3 words and roughly 0.8 s spoken.
- An entry never names an action: no "turning", "setting", "adding", "sending", "checking" or
  "doing".
- An entry never confirms: no "got it", "noted", "on it", "sure", "done", "will do" or "right away".
- An entry never asks the user to keep going: no "?", which also retires "Hm, go on?".
- Pauses come from punctuation (`…`, `—`), **not** SSML `<break>`. Cartesia's docs say a break
  splits the generation and sounds less natural, which is the opposite of the goal in a
  one-second clip.

**Why a bank, and not a better prompt:**

- The current prompt already offers "Hm." and "Oh?", and the model still drifts to
  acknowledgments.
- A curated list makes the "never confirms, never echoes" rule something a test can enforce.
- It deletes a Gemini call from every voice turn. That removes the cost, removes the 2–4.6 s
  `ttfa` outliers, and removes the failure path.

A bank is less contextual than a model, but a thinking sound is not supposed to carry context.
That is the point of the change.

### 2. A natural pause, then the beat

At the endpoint, in filler style on a user voice turn:

1. Pick the beat. **Start its TTS synth at once**, through the same batch path as today.
2. Arm a short **pause**: `filler_pause_ms`, jittered **350–650 ms**. That is a human response gap,
   and it covers the measured 230–280 ms synth, so the clip is normally ready when the pause ends.
3. The beat speaks when the pause has elapsed **and** the clip is ready. If the clip is late, it
   waits for it, exactly as the reflex waits today. A synth error goes straight to `:reflex_sent`
   with no audio, as today's TTS error does.
4. **If the brain's first audio lands inside the pause, the beat is skipped.** The answer itself is
   the response. This is today's `:brain_won` path (`reflex_mode: :race`), now on by default in
   filler style, where it costs nothing.

The Policy already has these phases (`:awaiting_reflex` → `{:reflex_ready, text}` →
`:speaking_reflex` → `:reflex_sent`), so **Policy is unchanged**. The pause and the pre-synth live
in the Conversation:

- The pause timer fires `{:reflex_ready, text}`.
- `{:speak_reflex, text}` uses the clip that is already synthesizing instead of starting a new one.
- An empty text (a silent beat, below) feeds `:reflex_sent` with no audio and no `speak_start`.

The **eager head-start** has nothing to precompute in filler style, so the speculative reflex does
not run there. `eager_reflex` keeps its meaning for `:model` style only. The `turn.start` TTS
pre-warm of the brain socket is untouched.

**A silent beat (optional, open question 3).** With probability `filler_silent_beat` (proposed
default `0.0`), the turn skips the beat altogether and the first sound Henry makes is the first
thinking filler (§3). The app's "thinking…" line and the orb already show that he heard.

Expected effect: `ttfa` goes from p50 0.96 s / p90 1.7 s with multi-second outliers to **0.35–0.65 s,
flat**, because there is no model call. The time to the answer does not change.

### 3. A thinking cadence for the long gap

Once the gate opens (`:reflex_sent`, phase `:streaming`) and no brain audio has been pushed
(`ttb == nil`), arm a `{:timeout, :filler_cadence}` (named apart from the `:thinking` client event):

- **Schedule:** `filler_cadence_ms: [4_000, 5_500]`. The first thinking sound comes 4 s after the
  beat **finishes playing** (measured from `audio_until`), the second 5.5 s after that, and that
  is the cap. Against production's gap (p50 6.3 s, p90 14.7 s), a typical turn hears *"Hmm." …
  "Mm…" … answer*. A slow tool turn hears two thinking sounds, never three.
- **Pre-synth when armed**, so it plays the instant the timer fires. A clip that isn't ready when
  its time comes is **skipped**, not waited on.
- **It stops for good** at the first brain audio push (an answer or a bridge), on any phase change
  away from `:streaming` (`brain_done`, barge-in, watchdog), and in `reset_turn_fields`. The `turn_complete` /
  `cancel_timers` paths clear it like the other turn timers.
- **User voice turns only** in v1: not typed turns, not agenda turns. A canned agenda item has no
  brain gap at all.

**Audio accounting, which is load-bearing:**

- Cadence clips are pushed with the **`:reflex` source**, so they count in `reflex_ms`.
- They always come before the first brain audio on the timeline, because the cadence stops when
  that audio arrives.
- Together these keep the interrupted-turn rule, `heard = played_ms - reflex_ms`, correct.
  Pushing them as `:brain` would make every interrupted filler look like a heard answer.
- A brain chunk that lands while a filler is still playing queues behind it, for at most ~0.8 s.
  That is accepted, and the clip-length rule keeps it small.

Cadence clips go through the **batch** synth, not the brain's Cartesia WS context. They cannot
touch context expiry or the rotation logic in `BrainStream`.

Barge-in needs nothing new. Speech during a filler is a `turn.start` in a non-listening phase,
which ducks and waits for confirming words, exactly as it does during the reflex. If the mic picks
up Henry's own wordless filler ("Mm…", "Hmm…", "Uh…"), `Backchannel` classifies it as
`:backchannel` and he carries on. A worded one ("Let's see…") has the same echo exposure as
today's reflex ("On it—"), no more.

### 4. Bridges stop echoing writes

A bridge earns its place when it tells you **what you are waiting on**. "Let me look." warns you
the camera is about to fire, and "Checking your calendar, one moment." explains a multi-second
fan-out. A bridge that only acknowledges a write is the echo the issue asks to remove, and the
answer confirms the write anyway.

| keep (they explain a wait) | drop (`bridge/1` returns `[]`) |
|---|---|
| `look`, `get_calendar_events`, `search_email`, `read_email`, `get_weather`, `recall_memory`, `home_status`, `code_board` | `home_control` ("On it.", "Doing that now."), `play_music`, `run_routine`, `create_event`, `send_email`, `start_claude` |

With a dropped bridge, §3's cadence covers the tool gap. A home turn then sounds like
*"Mm-hm." … "Kitchen lights are off."* instead of *"On it—" "On it." … "Kitchen lights are off."*
This is open question 4: it could also ship as its own issue.

### 5. Thread, orb and dashboard

- Fillers are spoken with a new **`speak_start` source `filler`**, used for both the beat and the
  cadence.
- **Native:** `lineKindFromSource` learns `filler` and deliberately returns no thread line. The
  turn event still applies, so the orb shows speaking, and the audio plays as usual (the client
  ignores the source for audio). Today an unknown source is dropped with an `unknown speak_start
  source` log; the new source should be an explicit case, not that accident. The existing
  "thinking…" line stays up until the answer arrives, which is the right picture during a filler.
- **Dashboard mirror:** fillers render as a `filler` aside. This is the admin inspector, and
  seeing what Henry actually said is its job. Saved history is unaffected: it only carries `you`
  and `assistant`.
- **Persistence:** `reflex_text` stores the beat's text, or nil when skipped or silent.
  `reflex_ms` includes cadence audio.

### 6. Config and rollback

Everything goes in `App.Config`; no env vars.

| key | default | meaning |
|---|---|---|
| `reflex_style` | `:filler` | `:model` keeps today's path verbatim, as a one-release rollback (open question 5) |
| `filler_pause_ms` | `{350, 650}` | jittered pause before the beat |
| `filler_cadence_ms` | `[4_000, 5_500]` | thinking-sound schedule; `[]` turns the cadence off |
| `filler_silent_beat` | `0.0` | chance of skipping the beat (a pure pause) |

`reflex_mode` only means something in `:model` style. When `:model` is retired, these go with it:
`reflex_prompt/1`, the `:reflex` tier, `model_reflex`, `reflex_thinking`, the speculative reflex
and `eager_reflex`. CLAUDE.md's pipeline line and gotchas that mention the reflex model, eager
head-start and the 3.6 `minimal` constraint get updated in the same change.

### 7. Logs

One greppable line per decision:

- `[filler] beat <id> after <n>ms`
- `[filler] skipped — the brain answered in the pause`
- `[filler] thinking <id> at +<n>ms`
- `[filler] cadence stopped (<reason>)`

Filler ids and text are Henry's own canned words, not anything a user said, so they don't need
`App.LogText.said/1`. The `[turn] metrics` line is unchanged; `ttfa` now measures the pause plus
the beat.

## Testing

- **`FillersTest` (pure):**
  - a table of `shape/1` cases;
  - every bank entry obeys the bank rules (word count, the forbidden-word list, no `?`);
  - `pick/3` honours the no-repeat window;
  - `:silence` only when asked for.
- **`ConversationTest`** with the fake TTS and fake brain, `TextModelMock`, `async: false`:
  - A voice turn speaks a bank filler after the pause and makes **no `:reflex`-tier model call**
    (Mox `expect` with zero calls).
  - Brain audio inside the pause skips the beat (`:brain_won`): no `filler` `speak_start`, and the
    brain audio is the first audio.
  - With a slow brain (`:fake_brain_done_ms`), cadence fillers are pushed on schedule and capped at
    the length of `filler_cadence_ms`. The first brain audio stops them.
  - `brain_done`, barge-in and watchdog each stop the cadence, and no filler lands after the turn.
  - **Interrupted-turn persistence** with cadence audio in `reflex_ms` still decides "answered"
    vs "carried forward" correctly.
  - Typed and agenda turns get no filler and no cadence. Agenda leads are byte-for-byte unchanged.
  - `reflex_style: :model` still passes the existing reflex tests.
- **Tool bridges:** the dropped bridges return `[]`, and the kept ones are unchanged.
- **Native:** a `filler` `speak_start` adds no thread line but plays and drives the orb. Gates are
  `flutter test` + `flutter analyze`.
- **Live smoke (David), on the wall and the phone:**
  1. Render every bank entry once with the live voice, using a throwaway `mix run` script in the
     plan, and drop any that Toby says badly.
  2. Run ten mixed turns (a question, a home command, a remark, a slow calendar or tool turn) and
     listen for whether it ever sounds like an acknowledgment.
  3. Check whether the cadence ever feels nagging, and whether a fast answer still lands without
     a filler.

## Alternatives considered

- **Keep the model and rewrite the prompt.** Rejected: the drift is already happening with "Hm."
  in the examples, the rules can't be test-enforced, and it keeps the per-turn call and its
  outliers.
- **A pre-rendered clip cache** (synthesize the bank once per voice). Deferred: live synth already
  fits inside the pause, and identical clips repeat audibly. Revisit only if `ttfa` regresses.
- **A device earcon or soft non-speech sound.** Rejected for v1: it needs a new native asset and
  a playback path beside `AudioRouteOwner`, and a chime next to a human voice reads as a machine.
  Cartesia documents `[laughter]` but no hum or breath cue.
- **A silent reflex with no first beat at all.** That is offered as the `filler_silent_beat` knob
  rather than the default, because the orb is not always in view (the wall across the room) and a
  long silence reads as "didn't hear me".

## Open questions for David

1. **The bank's wording.** Edit the table in §1 freely. Two judgement calls: does "Okay…" count as
   an acknowledgment to you, and should the fillers keep a little of Henry's dryness ("Hm.",
   "Huh.") or stay neutral?
2. **The cadence.** Is two thinking sounds at 4 s / +5.5 s right, or should it be one, or none
   (beat, then silence until the answer)?
3. **Silent beats.** Should a turn sometimes open with a pure pause (`filler_silent_beat > 0`), or
   should Henry always make a sound first?
4. **Bridges.** Should the write-echo bridges (§4) go in this change or in a separate issue?
5. **Rollback.** Should the `:model` reflex stay for one release behind `reflex_style`, or be
   deleted outright now?
6. **Where this doc lives.** `docs/superpowers/` is git-ignored ("kept local, not published"), so
   this spec was **force-added** there. That puts it where CLAUDE.md says designs live, and where a
   later build dispatch will look. Move it, or untrack it after approval, if you'd rather keep that
   directory local.
