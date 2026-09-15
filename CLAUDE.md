# CLAUDE.md — working guide for this project

Project-specific guidance for AI agents working on **P.A.I.** (Persona Assistant Interface), a
voice assistant in Elixir/Phoenix. The assistant you talk to is **Henry** — that name is settled by
`com.henry.henry_wall` and is not up for debate. (It is not fixed by any trained wake-word model:
the wake word is a tokenized keyword string in `native/assets/kws/keywords.txt`, so renaming Henry
is a one-line change plus a regenerated keywords file.) **Remi** was the original codename; it
survives nowhere in live code and should not be reintroduced.
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
`docs/superpowers/plans/`. **Backlog: the Forgejo issue board**
(`code.clausens.cloud/kalcode/personal-assistant/issues`, via `tea`; skill `tracking-issues`). New
bugs, debt and ideas go there, not into `IDEAS.md` or "Known debt" below (both predate the board).

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

## Repo layout (monorepo)

```
server/    Phoenix app — brain, tools, memory, channels + the LiveView web UI
native/    ONE Flutter project → Android (phone+tablet), desktop (macOS/Windows), iOS later
docs/, docker-compose*.yml, dev.sh, CLAUDE.md, AGENTS.md …   top level
```

**All `lib/…`, `test/…`, `config/…`, `assets/…`, `priv/…` paths in this file are relative to
`server/`.** Run every `mix` command from `server/`. The Flutter client is a *single* project —
phone/tablet/desktop are build targets + responsive layout inside `native/`, not separate folders.
Deploy: `docker-compose.yml` (Coolify) builds with `context: ./server`.

## Surfaces: Flutter is the target, the web is the monitor

**As of 2026-09-05 the web UI is no longer the reference implementation.** The Flutter client is
the product. The LiveView is being allowed to drift, and is slowly becoming a debugging /
monitoring / deep-analysis view rather than a second front end.

What that changes, concretely:

- **Do NOT keep the two aligned.** Native copy, layout, ordering and affordances are decided on
  their own merits — a 360dp phone is not a browser window, and matching the web was costing real
  usability (the connectors rows that truncated to `Google...` and `Google C...` were a direct
  result of porting the web's one-line row shape).
- **A divergence is no longer an exception that needs justifying.** Earlier phases documented each
  one; that framing is obsolete. Justify a *native* decision on native grounds.
- **Still true, and different:** panels must render what the CHANNEL sent (labels, facts,
  summaries) rather than inventing their own. The four `"the copy renders verbatim from the
  server"` tests assert THAT, not web parity -- keep them.
- The web still needs auth and still needs to work. A monitor you cannot log into is not a monitor.

Parity locks left over from the port, to retire as each file is next touched:
`connectors_panel_test.dart`'s "byte-exact with voice_modals.ex" test, `nav.dart:6`'s "**This
order is fixed**" (its reason -- phases B-D -- is complete), and `connectors_panel.dart:836`'s
byte-exactness claim.

## Gates (always, before any commit)

**From `server/`:** `mix precommit` = `compile --warnings-as-errors` + `deps.unlock --unused` +
`format` + `test`. Equivalent manual gates used per-task: `mix format` (+ verify `--check-formatted`),
`mix compile --warnings-as-errors`, `mix test`. JS changes also: `mix assets.build` must bundle clean
(no JS unit tests — the hook is **smoke-verified**).
**From `native/`:** `flutter test` + `flutter analyze` clean; Kotlin changes need
`flutter build apk --debug` (analyze does NOT compile Kotlin). Flutter is **not on PATH** — the SDK
lives at `~/flutter/bin` (prepend `export PATH="$HOME/flutter/bin:$PATH"; ` per command).

## Running it

`./dev.sh` (repo root — a thin delegator to `server/dev.sh`) loads `server/.env`, runs the server, and
tees output to `server/log/companion.log` (rotated to `.prev` each run). Port is `PORT` from `.env`
(**8787**, not 4000). `mix setup` (from `server/`) installs deps + DB + assets + npm.
**Read the logs to debug** — `server/log/companion.log` is the diagnostic surface,
and reading it (not guessing) has repeatedly been the thing that actually found bugs.
Semantic memory needs Qdrant: `docker compose -f docker-compose.dev.yml up -d` (dev-only, exposed on
`localhost:6333`, unauthenticated). Without it the embedder logs a harmless retry warning.

## Git / secrets

- The user works **directly on `main`** (explicit consent — no feature branches needed).
- **Commit only when asked; push only when asked, and confirm each push** (the auto-classifier will
  block an ambiguous push — get an explicit "yes, push").
- End commit messages with: `Co-Authored-By: Claude <noreply@anthropic.com>`.
  Version-free on purpose — a pinned model name goes stale the moment the model changes,
  and following it then writes a false attribution into the history.
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
- **Ink-2 bills 3 credits/second, not 1** — published sources disagree, and the user's own dashboard
  settles it: a peak day of ~220K credits is 20.4h of audio at 3 credits/s versus a physically
  impossible 61h at 1 credit/s. This is how July's 1,105,547 STT credits resolve to ~102h rather
  than an impossible 307h — i.e. there is no leaked-socket bug to hunt.
- **The morning briefing waiting for a wake is DELIBERATE, not a regression.** With
  `voice_activation` defaulting on, an `:after_next_turn` briefing no longer fires the moment the
  socket connects — it waits until you actually say "Henry". That is the point: a connected device
  is not a present human, and a briefing spoken to an empty room is worse than one that waits. If
  a future change makes the briefing bypass the gate, it has broken a property the user chose on
  purpose (2026-09-11). Fired **reminders** are different and correctly DO bypass it — they run
  `:when_idle` → `start_agenda_turn` → `feed/2`, because a reminder is explicit prior intent.
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
- **Model IDs:** per-tier Gemini (`App.Config :model_brain` = `gemini-3.8-flash` @ `medium`,
  `:model_reflex` = `gemini-3.6-flash` @ `minimal`), Cartesia STT `ink-2` (`:stt_model`), Cartesia
  TTS Sonic (`:tts_model`). **3.7+/3.8 Flash reject `minimal` thinking (400)** — the reflex must stay
  on a model that accepts it; at `low` those models think 0–500 tokens (2–3.5s tail, blows the
  24-token reflex cap). Probed 2026-09-11.
- **Two-user model:** `App.Users` + `:allowed_users` allowlist (each entry = canonical `email` +
  optional `aliases`, all log into one instance, keyed by canonical email).
  Per-user scoping by `user_id` across turns/reminders/profile_facts/summary/google_accounts.
  Session key = `to_string(user.id)`; `App.Users.id_from_session/1` parses it back. Voice socket
  authed via `Phoenix.Token` (`UserAuth.authenticate_socket/1`); `load_user/1` re-checks existence
  + allowlist on every request. Memory `context/2` + `Updater.run/1` guard non-integer session ids.
- **Authentik is the IDENTITY provider; Google is a CONNECTOR provider.** Two unrelated things
  that both speak OAuth. Authentik (`auth.clausens.cloud`, application slug `orbital`) answers
  "who are you"; Google answers "what did you grant access to" (Calendar/Gmail) and its Cloud
  console setup is untouched by any of this. `App.Auth.Oidc` and `App.Google.OAuth` are
  deliberately separate modules — do not merge them. ONE Authentik application serves local and
  prod, with both redirect URIs registered on it; only `OIDC_REDIRECT_URI` differs per env.
- **OIDC endpoints come from the discovery document, never from joining paths onto the issuer.**
  Authentik's issuer carries the application slug (`/application/o/orbital/`) while the endpoints
  do NOT (`/application/o/authorize/`, `/application/o/token/`). Deriving them 404s. `App.Auth
  .Oidc` fetches `<issuer>.well-known/openid-configuration` lazily on first use and caches the
  pair in `:persistent_term` (`reset_discovery_cache/0` is the test seam — tests that stub
  discovery MUST clear it or the first stub leaks into the rest of the file).
- **An Authentik user with no email cannot log in**, and the error does not say so. Identity is
  keyed on the OIDC `sub`, but `App.Users.upsert_from_oidc/1` gates an *unknown* subject on
  `ALLOWED_USERS` by email — `:allowed_users` is deliberately retained as a SECOND gate behind
  Authentik's own group binding, so both must pass. Set each Authentik user's email to match the
  allowlist exactly. Ordering in that function is load-bearing: the subject match returns BEFORE
  the allowlist check, so a changed email still resolves to its row. Note what that costs, because
  an earlier version of this line got it wrong: `UserAuth.load_user/1` re-checks the allowlist on
  every request against the **stored** email, and the subject-match path never updates it — so
  changing someone's email in Authentik does NOT evict them. To evict, remove them from
  `ALLOWED_USERS` (or deactivate them in Authentik), which does take effect on the next request.
  The lookup that binds an existing row searches the entry's canonical email AND its aliases: an
  entry whose `email` is repointed while its old address becomes an alias must still find the
  original row, or that row's turns/facts/connectors are stranded under an id nobody logs into. An allowlisted email whose row
  is already bound to a DIFFERENT subject is `{:error, :subject_conflict}` — refuse, never rebind,
  or one user silently inherits the other's turns, facts and connectors.
- **The native app signs in like the web — there is no token to paste.** `kSocketToken` is gone
  from `config.dart`; tapping Sign in opens `/auth/login?return=app` in the OS auth session
  (`flutter_web_auth_2`; a Custom Tab, so still the system browser — an embedded webview is refused
  by most IdPs), the server ends on `orbital://auth?code=…`, which the session returns to the app
  and dismisses itself on, with a **single-use 60s code**, and the app exchanges it at
  `POST /api/auth/exchange` for a token it keeps in platform secure storage. Single-use + 60s only
  defeats a *later* replay of a captured code (browser history, Android's intent log, a nosy
  reader) — it does NOT defend against *interception*, since the `orbital` intent-filter (on the
  package's `CallbackActivity`) is open to every app on the device and any of them can win the
  chooser and take the code first. PKCE is the real mitigation for that and is deliberately not
  implemented, on the reasoning that this is a two-user personal instance.
  Don't overstate the code's guarantee as "the token never rides a URL" either — that's true only
  of *this deep link*; the token still rides the socket URL's query string (`kSocketUrl`,
  pre-existing), which reaches Cloudflare's access logs on every connect.
- **A refused token and an unreachable server are different, and the app must keep treating them
  so.** Rejected → clear the stored token and show the login screen. Unreachable → **keep** the
  token and retry on the existing backoff. Backwards, and you are signed out every time wifi
  drops. `AppConnection.onRejected` carries this, and `main.dart` must PASS it — it shipped
  unwired once, fully tested and completely inert, because the test seam supplied its own
  connection. That seam now takes `onRejected` as a parameter for exactly that reason. The
  classifier itself (`_isRejection`) can only see a `WebSocketChannelException` whose message
  names a failed upgrade — `dart:io` raises that exact string for **every** non-101 response, so a
  Cloudflare 502 mid-redeploy or a captive portal's login page look identical to an actual 403 at
  that layer. `AppConnection` confirms the ambiguous case against `GET /api/auth/session`
  (bearer token; 401 = genuinely rejected, anything else including a network failure = treat as
  unreachable) before ever clearing a token — only a confirmed 401 reaches `onRejected`.
- **The app never sets its own connection back to null on sign-out — `_teardownShell` in
  `main.dart` does it.** `_conn` used to be assigned once and never reset, so a rejected token
  cleared correctly but left the user staring at a dead `MeridianVoiceScreen` with no way back to
  `LoginScreen` short of an app restart. `_onAuthChanged`'s `signedIn → signedOut` edge now tears
  the shell down (disposes every client built alongside the connection, then nulls them) so
  `build()` falls through to the login screen again.
- **The app's `SERVER_HOST` and `OIDC_REDIRECT_URI`'s host must be the SAME STRING**, not merely
  the same machine. `127.0.0.1` and `localhost` are different cookie hosts: the session carrying
  `:oidc_state` is stored against whichever the app opened, Authentik redirects back to whichever
  `OIDC_REDIRECT_URI` names, and if they differ the cookie is not sent — state mismatch, every
  time, on an otherwise perfect flow. Cost a live smoke session; the run scripts all say
  `localhost` to match `.env`. (adb reverse serves both names.)
- **The server address is `--dart-define`d** (`native/lib/server_config.dart`), defaulting to
  production. TLS is inferred from the port rather than configured separately — two knobs that
  must agree is one too many, and the failure (`ws://` against a `wss://` endpoint) is a silent
  hang.
- **`native/_target.sh` is the ONE place a run script decides where a build points**, arms the
  `adb reverse` tunnel, and prints the `▸ target:` banner; `run-dev.sh` (debug) and
  `run-profile.sh` (profile) default local, `run-build.sh` (release APK: build + install +
  launch) defaults prod, and each takes `--prod`/`--local` plus an optional device id. It reads
  the PROD host/port by parsing the `defaultValue`s out of `server_config.dart` rather than
  repeating them, so the banner cannot describe a build that wasn't made. That structure is the
  fix for two drift bugs in one week: `run-profile.sh`'s banner still advertised `127.0.0.1`
  after `run-dev.sh` moved to `localhost`, and a comment placed BETWEEN two `\` continuations
  commented out the rest of the joined line and silently dropped both `--dart-define`s, pointing
  a "dev" run at production.
- **One app at a time on the device, by choice.** Every build type shares `applicationId`
  `com.orbital.pai`, so a release install replaces a debug one. The obvious fix — an
  `applicationIdSuffix` on debug — is worse: both apps would register the `orbital://`
  intent-filter, so every auth/connector return pops the Android chooser and the single-use login
  code goes to whichever app wins. Switching targets costs a **sign-in, not a reinstall**:
  release is signed with the DEBUG keystore (`build.gradle.kts`) so `install -r` works both ways
  and secure storage survives, but the stored token was signed with the other server's
  `SECRET_KEY_BASE` → socket refused → `/api/auth/session` confirms 401 → token cleared → login
  screen. That is the designed path, and the first real exercise of the rejection classifier.
- **Cloudflare fronts `auth.clausens.cloud` and blocks non-browser POSTs** to the Authentik API
  with `403 error code: 1010` (its browser-signature check). GETs pass. `curl` gets through;
  Python `urllib` does not. If a script against that API 403s with a body that is not JSON, it is
  Cloudflare talking, not Authentik.
- **Coolify + Cloudflare-tunnel deploy gotchas:** `force_ssl OFF` in `config/prod.exs` (TLS
  terminated upstream by CF → otherwise redirect-loop); `SECRET_KEY_BASE` ≥64 bytes (Plug cookie
  store); **host has no IPv6 egress** → `App.Finch` connect timeout 10s + `/etc/gai.conf` IPv4
  precedence in the Dockerfile (the BEAM tries AAAA first and stalls — first cold call slow ~4.8s,
  concurrent calendar fan-out can `pool_not_available` until warm; IPv4-only is the real fix, TBD);
  SQLite on a persistent `/data` volume (else redeploys wipe data), container runs as root for
  volume writes; register BOTH redirect URIs (localhost + prod) in the Google Cloud console; deploy
  is `App.version`-stamped — bump `version:` in mix.exs before deploying (shows in footer + boot
  log). **But** a `mix.exs` edit invalidates the Docker deps layers (cold Rust + EXLA rebuild):
  read issue #1 before bumping.
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
