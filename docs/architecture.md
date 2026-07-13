# Architecture

A low-latency, household voice assistant built on Elixir/Phoenix. One BEAM node owns the whole
pipeline: browser mic audio streams over a Phoenix channel into a per-user conversation state
machine, which fans out to streaming STT (Cartesia Ink-2), a streaming LLM brain (Gemini) with
inline tool calls, and streaming TTS (Cartesia Sonic) — with a "reflex" filler phrase covering the
brain's first-token latency. Memory, reminders, connectors, and a speaker-verification gate
("Voice Lock") hang off the same core.

The assistant's name is configurable (`App.Config :name`); this doc calls it "the assistant".

## System overview

```mermaid
flowchart LR
  subgraph Browser
    MIC["Mic capture<br/>(AudioWorklet, 16 kHz PCM16)"]
    PLAY["Playback<br/>(WebAudio, gapless queue)"]
    UI["LiveView UI<br/>(panels, live captions)"]
    HOOK["Voice hook<br/>(binary channel client)"]
    MIC --> HOOK
    HOOK --> PLAY
  end

  subgraph Phoenix["Phoenix (one BEAM node)"]
    VC["VoiceChannel<br/>(binary audio in / events out)"]
    EC["EnrollChannel<br/>(Voice Lock clips)"]
    CL["ConversationLive<br/>(UI state, settings)"]
    CONV["Conversation<br/>(gen_statem, one per user)"]
    POL["Policy<br/>(pure turn reducer)"]
    GATE["App.Speaker<br/>(Voice Lock gate)"]
    BS["BrainStream<br/>(Gemini SSE → TTS WS)"]
    TOOLS["App.Tools registry<br/>(timeout + crash guard)"]
    MEM["App.Memory<br/>(facts, summary, recall)"]
    AGENDA["Agenda + Schedulers<br/>(reminders, briefing)"]
    DB[("SQLite<br/>(persistent volume)")]
  end

  subgraph External["External services"]
    INK["Cartesia Ink-2 STT<br/>(semantic turns, WS)"]
    SONIC["Cartesia Sonic TTS<br/>(WS stream + REST)"]
    GEM["Gemini<br/>(brain / reflex / memory tiers)"]
    GOOG["Google APIs<br/>(Calendar, Gmail, OAuth)"]
    METEO["Open-Meteo"]
    VOY["Voyage embeddings"]
    QD[("Qdrant<br/>(semantic index)")]
    HA["Home Assistant hub<br/>(optional)"]
  end

  HOOK <-->|"binary PCM / JSON events"| VC
  UI <--> CL
  HOOK <--> EC
  VC <--> CONV
  EC --> GATE
  CONV --> POL
  CONV --> GATE
  CONV -->|audio| INK
  INK -->|"turn events"| CONV
  CONV --> BS
  BS <--> GEM
  BS <--> SONIC
  GEM -->|"function calls"| TOOLS
  TOOLS --> METEO & GOOG & HA
  TOOLS --> MEM & AGENDA
  CONV <--> MEM
  AGENDA --> CONV
  MEM <--> DB
  AGENDA <--> DB
  GATE <--> DB
  MEM --> VOY
  MEM <--> QD
```

Two users share one instance (an allowlist keyed by canonical email). Everything user-facing —
turns, reminders, profile facts, summaries, Google accounts, voiceprints — is scoped by `user_id`.
The voice socket is authenticated with a `Phoenix.Token`; each user gets exactly one
`Conversation` process, found via a `Registry` and kept alive across reconnects by a linger.

## Anatomy of a turn

The pipeline is tuned so speech starts flowing back before the brain has finished thinking:

- **turn.start** (speech onset) pre-warms the brain's TTS websocket so the handshake is already
  done when the transcript lands.
- **turn.eager_end** (Ink predicts the user is done) speculatively starts the reflex LLM call;
  **turn.resume** cancels it.
- **turn.end** commits the turn — after the Voice Lock gate (below) — and the reflex + brain run
  in parallel. Brain audio buffers until the reflex has been spoken, then flushes seamlessly.

```mermaid
sequenceDiagram
  participant B as Browser
  participant C as Conversation (FSM)
  participant I as Cartesia Ink-2 (STT)
  participant S as App.Speaker (Voice Lock)
  participant R as Reflex (Gemini fast tier + TTS)
  participant BS as BrainStream
  participant G as Gemini (brain tier)
  participant T as Cartesia Sonic (TTS WS)

  B->>C: mic PCM frames (8 ms, binary)
  C->>I: forward frames (also teed into the Voice Lock ring)
  I-->>C: turn.start
  C->>BS: pre-warm TTS websocket
  I-->>C: turn.update (partials → live caption)
  I-->>C: turn.eager_end
  C->>R: speculative reflex (held, not spoken)
  I-->>C: turn.end (final transcript)
  C->>S: verify turn audio vs voiceprint
  S-->>C: pass
  par reflex path
    C->>R: commit reflex
    R-->>B: filler audio ("Let me check…")
  and brain path
    C->>BS: begin(transcript, memory context)
    BS->>G: streamGenerateContent (SSE)
    G-->>BS: text deltas
    BS-->>B: live caption deltas
    BS->>T: text continuations
    G-->>BS: tool call(s)
    Note over BS,G: App.Tools.execute runs concurrently,<br/>results feed back, loop up to a hop cap
    T-->>BS: audio chunks
    BS-->>C: brain audio (buffered until reflex spoken)
    C-->>B: gapless brain audio + final markdown caption
  end
```

**Barge-in** is server-side: a `turn.start` while the assistant is speaking ducks playback
instantly; the next partial with real words confirms the interrupt (stop playback, cancel brain).
An interrupted turn is persisted if already answered, else carried forward so the brain answers
both requests in one go.

**Slow tools** get two covers: a spoken "bridge" phrase (canned filler that never enters the
transcript), and TTS **context rotation** — Cartesia contexts expire ~1 s after their last audio,
so when the brain goes quiet waiting on a tool, `BrainStream` detects the premature `done` and
streams the eventual answer on a fresh context id over the same websocket.

## Turn state machine (Policy)

`Policy` is a pure reducer — the `Conversation` gen_statem owns processes, buffers, and timers,
and executes the effects Policy emits (`generate_reflex`, `start_brain`, `flush_brain`,
`stop_playback`, `cancel_brain`, …).

```mermaid
stateDiagram-v2
  [*] --> listening
  listening --> awaiting_reflex: endpoint / reflex + brain + watchdog
  awaiting_reflex --> speaking_reflex: reflex_ready / speak it
  awaiting_reflex --> streaming: brain_won / skip the reflex
  speaking_reflex --> streaming: reflex_sent, brain still working / flush brain audio
  speaking_reflex --> draining: reflex_sent, brain already done / flush + arm drain
  streaming --> draining: brain_done / arm drain
  draining --> listening: drained / turn_complete
  awaiting_reflex --> listening: barge_in | watchdog
  speaking_reflex --> listening: barge_in | watchdog
  streaming --> listening: barge_in | watchdog
  draining --> listening: barge_in | watchdog
```

## Voice Lock (speaker verification)

Only enrolled voices get through in open-mic mode — background speech and song lyrics stop
becoming turns. Per-user tri-state: **off** (default, byte-for-byte legacy behavior), **shadow**
(score + log everything, block nothing — the calibration phase), **enforce**. Push-to-talk is
never gated (it's the deliberate-intent escape hatch), and every malfunction fails **open**.

The verifier runs in-BEAM: mic PCM → Kaldi-compatible log-mel fbank (Nx on the EXLA backend) →
WeSpeaker ECAPA ONNX model under Ortex → L2-normalized embedding → cosine against the user's
enrolled voiceprint.

```mermaid
flowchart TD
  EP["turn.end arrives<br/>(mic-driven endpoint)"] --> MODE{"mode? / PTT?"}
  MODE -->|"off · nil · PTT"| FEED["feed the turn<br/>(legacy path)"]
  MODE -->|shadow| SH["feed immediately +<br/>async score & log<br/>(would_drop recorded)"]
  MODE -->|enforce| SLICE{"turn audio in ring?<br/>voiceprint enrolled?"}
  SLICE -->|no| OPEN["FAIL OPEN:<br/>feed + log fail_open"]
  SLICE -->|yes| LEN{"speech ≥ min_verify<br/>(~1.2 s)?"}
  LEN -->|"no (short turn)"| TRUST{"verified within<br/>trust window (15 s)?"}
  TRUST -->|yes| PASS2["pass (trusted)"]
  TRUST -->|no| DROP2["drop (short_no_trust)"]
  LEN -->|yes| EMBED["embed within 250 ms budget<br/>(fbank → ECAPA → cosine)"]
  EMBED -->|"error / timeout"| OPEN
  EMBED --> SCORE{"score ≥ threshold?"}
  SCORE -->|yes| PASS["pass (verified)<br/>refresh trust anchor"]
  SCORE -->|no| DROP["drop: no reflex, no brain<br/>log event + mic pulse"]
  PASS --> FEED
  PASS2 --> FEED
  DROP -.->|"audit list in panel"| PANEL["Voice Lock panel"]
  DROP2 -.-> PANEL
```

Enrollment is three guided ~10 s prompts read through the **same** browser capture path as live
turns (same `getUserMedia` DSP, so the voiceprint lives in the same audio domain):

```mermaid
sequenceDiagram
  participant P as Voice Lock panel (LiveView)
  participant H as VoiceEnroll hook
  participant E as EnrollChannel
  participant SP as App.Speaker
  participant DB as SQLite

  P->>H: push_event enroll:record (slot)
  H->>H: startCapture (same constraints as live mic)
  loop ~10 s
    H->>E: binary PCM frames
  end
  H->>E: clip_done (slot)
  E->>SP: enroll_clip(user, slot, pcm)
  SP->>SP: quality check (length, RMS) → fbank → ECAPA embed
  SP->>DB: upsert clip (raw PCM + embedding + model id)
  E-->>H: ok / error(reason)
  H-->>P: enroll_result → panel refresh
  Note over SP,DB: voiceprint = normalized mean of clip embeddings.<br/>Raw PCM kept → model upgrades re-embed automatically.
```

Every gate decision is logged (pruned to the newest 100 per user); shadow mode's score
distributions drive threshold calibration (`App.Speaker.calibration_report/1` in iex), and the
panel's "recently filtered" list makes false positives discoverable.

## Memory

Three tiers: a bounded prompt context (no model calls on the hot path), a post-turn updater, and
a semantic index for recall.

```mermaid
flowchart TD
  subgraph Hot["Read path (every brain turn, bounded)"]
    CTX["Memory.context/2:<br/>profile facts + rolling summary + last 8 turns"] --> PROMPT["brain prompt"]
  end

  subgraph Write["Write path (off the hot path, per turn)"]
    TURN["persisted Turn"] --> UPD["Updater (memory-tier Gemini):<br/>rewrite summary + extract durable facts"]
    UPD --> FACTS[("profile_facts<br/>(auto capped, user-curated untouched)")]
    UPD --> SUM[("summary")]
  end

  subgraph Index["Semantic index (periodic)"]
    TURN --> EMB["Embedder (4 h): turns + nightly digests"]
    CONS["Consolidator (nightly digests)"] --> EMB
    ING["Sources Ingester (6 h):<br/>Gmail + Calendar items, per account"] --> VOYAGE["Voyage voyage-4-lite"]
    EMB --> VOYAGE
    VOYAGE --> QDRANT[("Qdrant")]
  end

  subgraph Recall["recall_memory tool"]
    Q["query"] --> FTS["SQLite FTS5 (keyword)"]
    Q --> SEM["Qdrant (semantic)"]
    FTS --> RRF["Reciprocal Rank Fusion"]
    SEM --> RRF
    RRF --> HITS["conversation hits from SQLite,<br/>email/calendar hits from the Qdrant payload<br/>(no live Google call)"]
  end
```

If the vector leg is down, recall degrades to keyword-only — same fail-soft posture as the rest
of the system.

## Reminders, agenda, briefing

All proactive speech funnels through one seam: producers hand `App.Agenda` an item, and the
user's `Conversation` decides *when* to say it (immediately if idle, queued to the next clean
turn boundary otherwise). Reminder turns run context-light so they fulfill in isolation.

```mermaid
flowchart LR
  TICK["Scheduler tick (15 s, DB-driven)"] --> DUE{"due & not fired?"}
  DUE -->|yes| FIRE["mark_fired<br/>(stamp = exactly-once,<br/>survives restarts)"]
  FIRE --> ITEM["Agenda item<br/>(personal / household / follow-up)"]
  ITEM --> PS(("PubSub<br/>agenda:user"))
  PS --> CONV["Conversation speaks it<br/>(idle now, else queued)"]
  CONV --> ACK["user acks by voice or panel"]
  FIRE --> ADV{"recurring?"}
  ADV -->|yes| NEXT["advance the same row to the<br/>next future occurrence<br/>(skips missed ones, no nudge loop)"]
  ADV -->|"no"| NUDGE["unacked one-shots →<br/>consolidated nudge at next connect"]
  BRIEF["Morning briefing (daily window):<br/>brain assembles it live from<br/>weather + calendar + reminders"] --> ITEM
```

## Tools

`App.Tools` is a registry over a `Tool` behaviour (`declarations/0` in Gemini function-declaration
shape, `execute/3`). Every call runs supervised with a per-tool timeout (default 8 s; Gmail's
multi-account fan-out gets 18 s) and a crash guard — a tool failure becomes an `{:error, …}`
function response, never a dead turn. An optional ETS cache (per-tool TTLs, write-invalidation)
skips repeat reads.

Registered today: **Weather** (Open-Meteo), **Reminders** (incl. recurrence + follow-ups),
**Lists** (shared household "books"), **Garden** (plant records + care coaching),
**Calendar** + **Gmail** (multi-account Google, sequential token refresh then parallel fetch),
**Recall** (hybrid memory search), and — only when a hub is configured — **Home Assistant**
(entity search/control with locks/alarms/garage read-only by construction).

## Supervision tree

```mermaid
flowchart TD
  APP["App.Supervisor (one_for_one)"] --> TEL["Telemetry"]
  APP --> REPO["App.Repo (SQLite)"]
  APP --> MIG["Ecto.Migrator"]
  APP --> PS["Phoenix.PubSub"]
  APP --> PRES["Presence"]
  APP --> CACHE["Tools.Cache (ETS)"]
  APP --> FINCH["Finch (HTTP pools)"]
  APP --> REG["Conversations.Registry"]
  APP --> TSUP["Conversations.TaskSup<br/>(reflex / tools / persists)"]
  APP --> DSUP["Conversations.Sup (DynamicSupervisor)"]
  DSUP --> S1["Session.Supervisor (per user)"]
  S1 --> CONV["Conversation (gen_statem)"]
  CONV -.->|starts, linked| STT["Stt.Cartesia (WS)"]
  CONV -.->|starts, monitored| BS["BrainStream (WS)"]
  APP --> EP["AppWeb.Endpoint"]
  APP --> OPT["gated children:<br/>Reminders.Scheduler · Briefing ·<br/>Consolidator · Embedder · Ingester ·<br/>Http.Warmer (prod) · Speaker.Ortex"]
```

Adapters (`:stt`, `:tts`, `:text_model`, `:brain_stream`, `:embeddings`, `:vector_store`,
`:speaker_verifier`) resolve through app env and are swapped for controllable fakes in tests; the
optional background workers gate on `start_*` flags so the test suite runs without them.

## Design throughlines

- **Latency is layered, not solved once**: prewarm at speech onset, speculative reflex at
  eager-end, reflex-covers-brain, buffered brain audio, TTS context rotation for slow tools.
- **Pure cores, thin shells**: `Policy`, `Gate`, `Ring`, recurrence math, and wake-word matching
  are pure modules with table-driven tests; processes own only I/O and timers.
- **Fail open, degrade soft**: Voice Lock malfunctions pass turns through; recall falls back to
  keyword search; per-account connector failures are reported, not fatal; STT exits reconnect on
  the next mic frame.
- **Exactly-once by stamps, not memory**: reminders fire off `fired_at` stamps and DB ticks, so
  restarts never double-fire or drop.
- **One writer**: SQLite's single-writer shapes real decisions — sequential token refresh before
  parallel fan-out, `async: false` DB tests, busy-retry on contended writes.
