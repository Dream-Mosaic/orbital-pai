# CLAUDE.md — working guide for this project

Project-specific guidance for AI agents working on **Remi**, a voice assistant in Elixir/Phoenix.
For framework rules (Phoenix v1.8, LiveView, Ecto, HEEx), read **`AGENTS.md`** — this file is the
*project* layer on top of it.

## What this is

A low-latency voice assistant. Pipeline: `mic → Cartesia Ink-2 STT → Conversation (gen_statem) →
reflex (instant filler) + streaming brain (Gemini SSE → Cartesia Sonic TTS) → audio`. The brain
calls **tools** (weather, reminders, Google Calendar, web search) inline mid-turn. Memory = profile
facts + rolling summary. Turn-taking = Ink-2 **native semantic endpointing** + push-to-talk (Ink
manual finalize) + barge-in (Ink `turn.start`). The brain answer text **streams to the UI live**
(plaintext caption → markdown on done); the reflex gets a head-start from `turn.eager_end`.

**Source of truth for what's shipped:** `docs/superpowers/2026-06-14-phoenix-build-status.md` (read
it first — it has a changelog + checkpoints). Designs: `docs/superpowers/specs/`. Plans:
`docs/superpowers/plans/`. Wishlist/roadmap: `IDEAS.md`.

## How we work (workflow)

This project is built with the **superpowers** skills, in order, and it has held up well:

1. **brainstorming** (HARD GATE) — every feature/refinement starts here. Do NOT write code until a
   design is presented and the user approves. Ask one question at a time; `AskUserQuestion` for forks.
2. **writing-plans** — turn the approved spec into a task-by-task plan (exact code, TDD, frequent
   commits) in `docs/superpowers/plans/`.
3. **subagent-driven-development** — execute each task with a fresh implementer subagent, then review
   (spec compliance + code quality), fix, move on. The user picks subagent-driven vs inline; they've
   consistently chosen subagent.

Each feature: brainstorm → spec (committed) → user reviews spec → plan (committed) → execute →
review → live smoke by the user → update the build-status doc. Decompose big asks into phases/
sub-projects, each its own spec→plan→ship.

**Bug fixes** (not new features) can skip the brainstorm gate — diagnose (read the logs!), fix
directly, test, commit, hand off for a re-smoke.

## Gates (always, before any commit)

`mix precommit` = `compile --warnings-as-errors` + `deps.unlock --unused` + `format` + `test`.
Equivalent manual gates used per-task: `mix format` (+ verify `--check-formatted`),
`mix compile --warnings-as-errors`, `mix test`. JS changes also: `mix assets.build` must bundle clean
(no JS unit tests — the hook is **smoke-verified**).

## Running it

`./dev.sh` loads `.env`, runs the server, tees output to `log/companion.log` (rotated to `.prev` each
run). Port is `PORT` from `.env` (**8787**, not 4000). `mix setup` installs deps + DB + assets + npm.
**Read the logs to debug** — `log/companion.log` is the diagnostic surface,
and reading it (not guessing) has repeatedly been the thing that actually found bugs.

## Git / secrets

- The user works **directly on `main`** (explicit consent — no feature branches needed).
- **Commit only when asked; push only when asked, and confirm each push** (the auto-classifier will
  block an ambiguous push — get an explicit "yes, push").
- End commit messages with: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- **Secrets** (`GOOGLE_API_KEY`, `CARTESIA_API_KEY` (STT + TTS), `GOOGLE_CLIENT_ID/SECRET`)
  live in `.env` (gitignored). Confirm key *names* only; **never print values**, never commit them.
- Leave the user's own uncommitted edits alone unless they ask you to commit them.

## Architecture map

- `lib/app/conversations/` — `Conversation` (`:gen_statem`, `:handle_event_function`), `Policy` (pure
  turn reducer), `BrainStream` (Gemini SSE → Cartesia WS), `Sessions`.
- `lib/app/adapters/` — `Stt.Cartesia` (Ink-2), `TextModel.Gemini`, `Tts.Cartesia` (Sonic) (+
  behaviours; swapped for fakes in tests via app env `:stt`/`:tts`/`:text_model`/`:brain_stream`).
- `lib/app/tools/` — `Tool` behaviour + `App.Tools` registry (per-call 8s timeout/crash guard); tools
  listed in `App.Config :tools`.
- `lib/app/google/` (OAuth + Calendar + accounts), `lib/app/memory/` (facts/summary/turns/updater),
  `lib/app/reminders/` (context + scheduler + notice).
- `lib/app_web/` — `VoiceChannel` (binary mic in; speak_start/audio/etc. out), `ConversationLive`
  (memory + reminders + Google panels), `GoogleAuthController`.
- `assets/js/voice/` — `index.js` (the `Voice` hook: mic, gapless playback, live brain caption, PTT,
  toggle relays), `capture.js`, `playback.js`. (Turn detection + barge-in are now **server-side** via
  Ink, so the old client VAD/RMS knobs are gone; the tunables live on the server — see below.)

## Gotchas (hard-won — don't re-hit these)

- **Gemini 3 + function calling:** you MUST echo the part-level `thoughtSignature` back in the
  `functionCall` continuation or the next request 400s.
- **Gemini grounding + tools:** to use Google-Search grounding (`%{googleSearch: %{}}`) alongside our
  `functionDeclarations`, the request needs `toolConfig: %{includeServerSideToolInvocations: true}` —
  else every brain turn 400s and silently falls back to the tool-less batch brain. Toggle:
  `App.Config :web_search`.
- **Ink-2 STT = TWO endpoints, selected by `mode`** (`Stt.Cartesia`): `:auto` →
  `wss://…/stt/turns/websocket` (native semantic turns: `turn.start`/`turn.update`/`turn.eager_end`/
  `turn.resume`/`turn.end`); `:manual` (PTT) → `wss://…/stt/websocket` (`transcript`/`is_final`/`text`
  + bare-text `finalize`→`flush_done`). The PTT toggle **reconnects** the socket in the matching mode
  (`set_ptt`→`restart_stt`). Pure `route/2` maps both vocabularies to the same `{:stt_partial,_}`/
  `{:stt_endpoint,_}` owner messages, so the FSM turn contract is unchanged.
- **`Cartesia-Version` is a tested-date pin, NOT a model version** — one `App.Config :cartesia_version`
  (currently `2026-03-01`-era) shared by Sonic TTS + Ink-2 STT; bump it to the date you re-test against.
- **Cartesia TTS contexts expire 1s after their last AUDIO output** (their docs) — there is NO
  keepalive, and the timer is audio-based, so you CANNOT hold a context open with whitespace/empty
  continuations (they make no audio). When a tool round is slow, the **bridge** plays its ~2.5s of
  audio, the brain then goes silent waiting on the tool, and the context finalizes (`done`) → empty
  turn. Cure = **context rotation** (`BrainStream`): on a Cartesia `done` while the brain is still
  working (`gemini_done == false`), bump `context_seq` and stream the answer on a **fresh
  `context_id`** (`"#{context_base}-#{seq}"`) — the WS connection stays open across an expiry, Cartesia
  supports many contexts per connection. Don't "fix" a silent tool turn with a keepalive — that path
  is a dead end (it only *seems* to work when tools finish under ~6s).
- **`%Req.HTTPError{protocol: :http2, ...}` is a RED HERRING** — Req hardcodes `protocol: :http2` when
  it wraps *any* `%Finch.Error{}` (`deps/req/lib/req/finch.ex`), so `:http2` says nothing about the
  transport. `:pool_not_available` = the first outbound call after idle raced a cold Finch pool's
  lazy startup. Recovery = retry (Req already classifies it transient); use `App.Http.Retry.opts()`
  (in calendar/oauth/gmail) which retries ONLY *request-never-executed* errors (so it's safe for the
  POSTs), short backoff. `App.Http.Warmer` (prod-only, `:start_pool_warmer`) pre-opens the pools at
  boot to dodge the cold-connect entirely; it also logs per-host connect time.
- **Per-tool timeout:** optional `Tool.timeout/1` overrides the registry's 8s `@default_timeout_ms`
  (`App.Tools.execute/3` resolves it; `/4` is an explicit override for tests). Gmail search is
  multi-account + multi-roundtrip → 18s cap; layered as metadata fan-out 12s < per-account gather 15s
  < tool cap 18s. Big caps are SAFE now that the TTS context is rotated (the brain can wait).
- **Barge-in is server-side** (`turn.start` during a non-`:listening` phase + `allow_interruptions`,
  confirmed by the next `{:stt_partial}` with real words → `feed(:barge_in)` reuses the existing
  effect). Tunables: `@interrupt_window_ms`, `interrupt_words?` (in `Conversation`). An interrupted
  turn is **persisted if already answered, else carried forward** (`pending_request`) so the brain
  answers both — don't regress that. The `eager_end` reflex head-start is gated `App.Config :eager_reflex`.
- **Calendar fan-out:** refresh tokens **sequentially** (`ensure_fresh`) before the parallel fetch —
  concurrent refresh contends for SQLite's single writer (busy_timeout waits up to 5s) and blows the
  7s fan-out timeout, so "one of N accounts always errors, rotating". Account names match
  case-INSENSITIVELY; the result's `accounts_read` is how the brain knows an account is connected.
- **Reminder turns** run **context-light** (drop recent conversation turns) so a fired reminder
  fulfills in isolation; a `reminder_turn` marker on the FSM drives the canned lead + no-persist.
- **Memory tier** `maxOutputTokens` must be generous — Gemini counts thinking tokens against it, so
  summaries truncate mid-sentence if too low.
- **SQLite single-writer:** DB-touching tests are `async: false`; `conversation_test` uses a shared
  Ecto sandbox so background persist tasks don't `OwnershipError`. A residual intermittent
  `App.Google.AccountsTest` **"Database busy"** flake exists (passes on re-run) — not a regression.
- **Model IDs:** per-tier Gemini (`App.Config :model_brain` = `gemini-3.5-flash`, `:model_reflex` =
  `gemini-3-flash-preview`), Cartesia STT `ink-2` (`:stt_model`), Cartesia TTS Sonic (`:tts_model`).
  Re-check preview suffixes before relying on them.
- **Two-user model:** `App.Users` + `:allowed_users` allowlist (each entry = canonical `email` +
  optional `aliases`, all log into one instance, keyed by canonical email).
  Per-user scoping by `user_id` across turns/reminders/profile_facts/summary/google_accounts.
  Session key = `to_string(user.id)`; `App.Users.id_from_session/1` parses it back. Voice socket
  authed via `Phoenix.Token` (`UserAuth.authenticate_socket/1`); `load_user/1` re-checks existence
  + allowlist on every request. Memory `context/2` + `Updater.run/1` guard non-integer session ids.
- **Coolify + Cloudflare-tunnel deploy gotchas:** `force_ssl OFF` in `config/prod.exs` (TLS
  terminated upstream by CF → otherwise redirect-loop); `SECRET_KEY_BASE` ≥64 bytes (Plug cookie
  store); **host has no IPv6 egress** → `App.Finch` connect timeout 10s + `/etc/gai.conf` IPv4
  precedence in the Dockerfile (the BEAM tries AAAA first and stalls — first cold call slow ~4.8s,
  concurrent calendar fan-out can `pool_not_available` until warm; IPv4-only is the real fix, TBD);
  SQLite on a persistent `/data` volume (else redeploys wipe data), container runs as root for
  volume writes; register BOTH redirect URIs (localhost + prod) in the Google Cloud console; deploy
  is `App.version`-stamped — bump `version:` in mix.exs before deploying (shows in footer + boot
  log).
- **Gmail = second connector via the same pattern**: one `@connectors` registry entry +
  `App.Google.Gmail` adapter (`list_messages/2`, `get_message/2`, `send_message/2`) + pure helpers
  `App.Google.Gmail.Body` (MIME→plaintext) and `App.Google.Gmail.Mime` (attrs→RFC 2822, header-
  injection guarded) + `App.Tools.Gmail` (`search_email`/`read_email`/`send_email`). Scopes: read =
  `gmail.readonly`, write = `gmail.send` (write requests both). An already-connected account must
  **reconnect** to grant the new scopes (incremental consent; existing Calendar grant retained).
  **Enable the Gmail API in the Google Cloud console** — without it, both read AND send 403 with
  `accessNotConfigured`/`SERVICE_DISABLED`; the adapter flattens 403 → `{:http,403}` /
  `:needs_write_access` and drops the body, so it *looks* like a scope problem when it's the API
  being disabled (hit live 2026-06-25). **`gmail.send` is a restricted scope**: in Google testing
  mode the app stays unverified — refresh tokens can expire ~7 days, surfacing as `:needs_reconnect`.
  **`messages.list` returns ids only** — per-id metadata `get` fan-out is mandatory.

## Testing patterns

- Mox: the text model is `App.TextModelMock` (set_mox_global; `async: false`). TTS/STT/brain-stream use
  **fakes** (`App.Test.Fakes.*`). The fake STT notifies a registered `:fake_stt_observer`
  (`{:fake_stt_started, mode}` on connect, `{:fake_stt_push, _}`, `{:fake_stt_finalize}`) — handy for
  asserting the PTT reconnect/finalize paths. The fake brain has app-env knobs (`:fake_brain_done_ms`,
  `:fake_brain_error`, `:fake_brain_text_deltas`) and notifies `:fake_brain_observer`.
- HTTP adapters stub `Req` via app-env keys: `:weather_req_opts`, `:google_req_opts` (Req.Test plug).
- Pure helpers are exposed `@doc false def` so tests call them directly (e.g. `Stt.Cartesia.route/2`,
  `Calendar.account_matches?/2`, `Gemini.tools_block/1`, `Weather.build_*`).

## Known debt / next

- **Done & live-smoked:** the 3-phase **Ink-2 STT migration** (swap off Deepgram+Silero VAD; eager_end
  reflex head-start; stream brain text to the UI), the **barge-in redesign** (server-side `turn.start`,
  allow-interruptions toggle, context carry-forward), **Gmail** (second Google connector; read + send +
  threaded reply; live-smoked 2026-06-25), the **two-user foundation** (allowlist, per-user scoping,
  socket auth — multiple allowlisted users concurrent, each seeing only their own data), and the **Coolify
  production deploy** (your-domain.example.com behind Cloudflare tunnel; SQLite on persistent volume;
  IPv6/force_ssl/SECRET_KEY_BASE prod fixes). See the build-status checkpoints.
- TTS still receives markdown symbols (streamed); a streaming-safe strip is deferred.
- **Earmarked latency tune:** Cartesia TTS `max_buffer_delay_ms` defaults to 3000ms (we don't set it).
  Lowering it (with terminal-punctuation discipline) could cut first-brain-audio latency — its own
  smoke-gated side-quest. Our continuation/buffering usage already follows Cartesia's streaming docs.
- **Active next workstream: concurrent multi-user hardening** — (1) audit sockets + per-user
  `Conversation`/Registry isolation under real simultaneous load; (2) **shared rate-limit handling**
  (Gemini brain/reflex/memory + Cartesia STT/TTS + `App.Finch` pool are shared across all users —
  two concurrent conversations double load, risk provider 429s / pool starvation); (3) **IPv6
  cold-connect cure** (first post-idle call stalls ~4.8s on Coolify host — force IPv4-only outbound,
  exact Mint/Finch knob TBD).
- The connections arc continues: Obsidian/CouchDB, Home Assistant. **Recipes** (personal table +
  step-by-step) and a Kagi **research mode** are also queued in `IDEAS.md`. Shared resources
  (shared grocery list, partner calendar invites) are parked for a later design pass.
