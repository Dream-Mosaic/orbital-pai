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

## Surfaces: Flutter is the client, the web is the admin dashboard

**As of 2026-09-26 the web is the admin dashboard** (spec
`docs/superpowers/specs/2026-09-26-web-admin-dashboard-design.md`, #21). Flutter is the only
client, on every platform: Android now, desktop (#16/#17) and iOS later, with per-platform code
paths where a platform needs them.

- The web never joins `voice:` and never writes. It live-mirrors the conversation from PubSub
  (`"conversation:<uid>"`, `{:mirror, event}` from `Conversation.emit/2`), shows saved history,
  and has a read-only inspector. Any write it grows later must call the same context function
  the panel channel does. The old duplicate web write paths drifted from the channels in four
  ways (see the spec).
- Native copy, layout and affordances are decided on native grounds; there is no web to match.
- Panels must render what the CHANNEL sent (labels, facts, summaries) rather than inventing
  their own. The four "the copy renders verbatim from the server" tests assert that. Keep them.
- The web still needs auth and must still work: a dashboard you cannot log into is not a
  dashboard.

## Gates (always, before any commit)

**From `server/`:** `mix precommit` = `compile --warnings-as-errors` + `deps.unlock --unused` +
`format` + `test`. Equivalent manual gates used per-task: `mix format` (+ verify `--check-formatted`),
`mix compile --warnings-as-errors`, `mix test`. JS changes also: `mix assets.build` must bundle clean
(no JS unit tests, and no JS voice code left to test — the web has no voice client any more).
**From `native/`:** `flutter test` + `flutter analyze` clean; Kotlin changes need
`flutter build apk --debug` (analyze does NOT compile Kotlin). On David's Mac Flutter is **not on
PATH** — the SDK lives at `~/flutter/bin` (prepend `export PATH="$HOME/flutter/bin:$PATH"; ` per
command). On the Claude dispatch box (CT 109) `flutter`, the Android SDK and JDK are already on PATH,
and `.tool-versions` (repo root) pins Erlang/Elixir for mise — don't look for `~/flutter` there.

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
- Household layer (2026-10-10): `lib/app/timers*` (context + `Timers.Scheduler`), `lib/app/messages*`
  (intercom between household members), `lib/app/trackers*`, `lib/app/routines*`, `lib/app/recipes*`,
  each with its tool in `lib/app/tools/`. `lib/app/cards.ex` (tool result → display-ready card),
  `lib/app/glance.ex` (the idle orb's weather + next event), `lib/app/backup.ex` (nightly snapshots).
- Toolkits + home (2026-10-19): `lib/app/toolkits.ex` (catalog, preselection, the per-turn open
  set), `toolkits/toolkit.ex` (behaviour), `toolkits/home.ex`, `tools/use_toolkit.ex`;
  `lib/app/home_assistant/{directory,resolve,actions,socket,live,phrases,media}.ex` (live WS
  directory, the words → entities resolver, REST writes, the socket, the supervised glue, the
  names preselection matches, Music Assistant players).
- Claude dispatch (2026-10-21): `lib/app/dispatch*` (jobs, `Forge` API client, HMAC-signed callback
  endpoint, `Notifier`, `Watchdog`, `Board`), `lib/app/toolkits/repos.ex` (the repos kit: board,
  start_claude, claude_jobs, file_issue) and `lib/app/tools/claude_dispatch.ex`.
- Wall tablet (2026-10-23, epic #38): server `lib/app/conversations/scope.ex` (the bound
  device's household/personal scope); native `lib/device/` (device role, `henry/window`
  channel, `WallModeHost` + `WallActivityScope`), `lib/meridian/wall_type.dart` (the wall type
  floor), `lib/meridian/today_board.dart` (the at-rest board; `App.Glance` feeds it).
- `lib/app_web/` — `VoiceChannel` (binary mic in from the app; speak_start/audio/etc. out),
  `ConversationLive` (the read-only admin dashboard: live mirror + inspector),
  `AppWeb.DashboardPanels`, `AppWeb.Dashboard.Mirror`, `GoogleAuthController`.
- `assets/js/`: just LiveView bootstrap; the web has no voice client.
- Native additions: `lib/meridian/composer.dart` (Type to Henry), `timer_strip.dart`, `orb_face.dart`
  (+ `lib/voice/glance.dart`), `lib/meridian/cards/` (one widget per card type, `card_view.dart`
  dispatches), `lib/voice/timers_model.dart`, `lib/audio/alarm_sound.dart` (+ `AlarmPlayer.kt`),
  `lib/notify/` (background notifications), `lib/meridian/books_*.dart` (recipe/tracker/routine
  shelves), `lib/meridian/wall_layout.dart` (breakpoints: compact < 600dp is the phone column,
  UNCHANGED; medium 600–899 a larger column; expanded ≥ 900 two panes — orb + timers + composer
  left, thread + nav right). A new voice-screen child must be placed in BOTH builders.

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
- **The `history` push is the DB tail PLUS the session's unsaved turns** (`Conversation.unsaved_turns/1`:
  the turn in flight, a carried-forward request, an interrupted answer awaiting its `played`
  report). A turn persists only when it ends, so a DB-only history given to an app reopened
  during a stuck brain showed nothing said after the hang (#32). DB first, then the call: a turn
  landing in between is missed, never doubled. A **blank batch-fallback answer** speaks
  `@brain_unreachable` like a failed one; it used to end the turn silently on the reflex.
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
  is `App.version`-stamped from **`server/priv/VERSION`**, read at runtime — bump it with
  `./bump.sh server patch|minor|major` before deploying (footer, boot log, Settings ▸ About).
  **Never bump `version:` in mix.exs** — it is frozen: the Dockerfile's deps layers are keyed on
  mix.exs, so any edit there forces a cold Rust + EXLA rebuild (issue #1). The app's version is
  separate: `./bump.sh app …` (pubspec + `kAppVersion`, test-locked together).
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
- **Tools advertise themselves.** A tool's usage guidance lives in its own optional `prompt/0`
  (`App.Tools.prompt_block/1` appends every enabled tool's fragment). Never grow the giant
  `Gemini.brain_prompt/1` string for a new tool — that paragraph was a guaranteed merge conflict.
- **Canned agenda items** (`App.Agenda.Item.canned: true`) speak `prompt` VERBATIM in the brain
  slot — TTS only, no model call, no BrainStream. Timers, household messages and calendar
  heads-ups use it: the words are already known, and a brain round would only add latency and
  paraphrase. `speak_start`'s source is the item's `kind`, so every new kind needs a native
  `LineKind` or the line is silently dropped (`lineKindFromSource` returns null).
- **Typed turns are QUIET** (`Conversation.typed/2`): Policy `{:endpoint_quiet, t}` starts the
  brain with `reflex_sent: true` and no reflex; `BrainStream` runs `tts: false` (no Cartesia
  socket); fallbacks send text only. A typed message claims like `ptt_press`, bypasses the wake
  lock / PTT / Voice Lock gate, and never unlocks. `quiet_turn` must reset on EVERY turn exit
  (`reset_turn_fields`, `:cancel_brain`) or the next spoken turn goes silent.
- **Cards ride the tool loop.** `Gemini.run_rounds` relays each `{:ok, r}` as
  `{:gemini_tool_result, …}` → `App.Cards.from_tool/3` (pure, nil when not card-shaped) →
  `{:card, card}`, HELD behind the reflex in `card_buffer` exactly like caption deltas. A carded
  result also gets a `display` note in its functionResponse (`Gemini.with_card_note/4`) so the
  brain gives the takeaway instead of reciting what the card already shows — without it, a weather
  card came with a seven-day monologue underneath.
- **Routine hop refund.** `@max_tool_hops` is 3 and `run_routine` spends a hop before any step
  runs; the FIRST `run_routine` of a turn refunds itself plus `@routine_bonus_hops` (once per turn,
  so re-calling it can't loop).
- **Timers are per USER, watched by the channel, not the Conversation.** `VoiceChannel` subscribes
  to `"timers:<uid>"` after join, so every device of the user shows every timer; the ring is
  spoken via a canned agenda item AND sounded on-device through the `henry/alarm` MethodChannel
  (`AlarmPlayer.kt`, `USAGE_ALARM` ringtone) — which must never take audio focus or touch the mode
  or route; `AudioRouteOwner` stays the only owner. `remaining_ms` is computed at push time and
  the client anchors it to its own monotonic clock (no clock skew).
- **The glance is built from real tools, off the channel process** (`App.Glance` via
  `App.Tools.execute/3`, so it shares the tool cache), refreshed every 15 min. `config :app, glance:
  false` in test — otherwise every channel test runs weather + calendar.
- **A joined standby device keeps the session alive.** The 2-minute linger used to stop the
  session when the BOUND device left even while another device sat in standby — and stopping
  takes the standby's channel down too (it monitors the session). It now re-arms while any other
  joined channel is alive.
- **Lists find-or-create runs IMMEDIATE.** The brain makes parallel tool calls in one round
  ("add milk", "add eggs"); each used to find no "groceries" and create its own — duplicate books,
  the panel showing one. `Lists.find_or_create_list/2` now takes the write lock up front and folds
  any same-name duplicates into the oldest. Any new read-then-create on the tool path needs the
  same (`Repo.transaction(fun, mode: :immediate)`) — SQLite returns BUSY_SNAPSHOT instantly, past
  `busy_timeout`, when a deferred transaction that already read tries to write.
- **Turn identity:** the canned line and the batch fallback are tracked as the turn's brain
  (`track_brain_task/2` → `brain_pid`/`brain_ref`) so an abort kills them; untracked, a timer
  announcement still synthesizing became the NEXT (typed) turn's answer. A claim mid-turn stops
  playback on the DISPLACED device before rebinding. An interrupted request carries the tools it
  already ran in `brain_note` (brain input only — never persisted as the user's words).
- **Heads-ups cover calendar AND rain** (`App.Agenda.Heads`, `App.Agenda.Rain`): both only for
  users with the `heads_up` pref on and a live device; rain polls Open-Meteo `minutely_15` every
  10 min only when someone is listening, one alert per rain event (re-arm after 2 h dry), ≤ 3 a
  local day, quiet 22:00–07:00. It requests `precipitation_probability` on minutely_15, which
  works but is undocumented — if Open-Meteo ever rejects it the whole request 400s and rain
  alerts go quiet (logged as fetch warnings).
- **Timers can be extended / snoozed** (`Timers.extend/3`, `add_to_timer`). A running timer keeps
  its ORIGINAL fire: the scheduler re-checks `ends_at` when it arrives and re-arms. Never arm a
  second fire for it — the duplicate landed mid-teardown in tests and caused `Database busy`.
- **"Henry, stop" / "okay" silence a ringing timer** (`silence_timers/1` in the safety-stop, wake
  command and — only when something actually rings — the bare-acknowledgement endpoint paths).
- **Background notifications** (`native/lib/notify/`): only while the app isn't `resumed`;
  timers ring once per id, message/reminder/heads-up leads pair with the next brain line (3 s
  fallback); everything cancels on resume. Local notifications from the live socket only — no FCM,
  no foreground service (#15/#18), so a killed process gets nothing.
- **Emulator smoke without Authentik:** run a throwaway server from a scratch worktree with
  `elixir --sname <name> --cookie <c> -S mix phx.server` (own DB copy, `HOME_ASSISTANT=false`, the
  Qdrant writers disabled), tap Sign in, then `adb shell am start -a android.intent.action.VIEW -d
  "'orbital://auth?code=<App.Auth.AppCode.mint(uid) via :rpc>'"`. A Phoenix-channel client script
  can push `"text"` for fully scripted typed turns. The debug APK (~260 MB) doesn't fit the stock
  AVD's /data — install a release `--target-platform android-arm64` build (~100 MB) instead.
- **Toolkits are opened per turn, and their guidance never enters the system instruction.** The
  catalog line is the only always-on text; a kit's guidance rides the user message (preselected)
  or the `use_toolkit` response, because anything in the system instruction busts Gemini's prefix
  cache for every turn. Declarations are GATED to opened kits but dispatch is PERMISSIVE (a call
  to a known tool works even if its kit was not opened), so a model that guesses a name is never
  punished with an error. A round containing only `use_toolkit` calls for NEW kits is a free hop
  (otherwise opening a kit eats the 3-hop budget), and a routine's steps can open a kit.
  Preselection (`wants?`) looks at the utterance plus the last 2 user turns within 10 minutes, so
  "make them blue" after "turn on the gaming lights" still opens the house. `wants?` runs before
  EVERY turn, so it must not do I/O or call another process: the house's names are computed once
  per directory build and read from `:persistent_term` (`App.HomeAssistant.phrases/0`). A kit a
  routine opens gets its guidance in that `run_routine` response. `use_toolkit` gets no UI chip
  on purpose.
- **The home directory is live over Home Assistant's WebSocket; writes stay REST.** The directory
  subscribes BEFORE it snapshots (else an event in the gap is lost), rebuilds on
  `*_registry_updated` and `homeassistant_started`, and when the socket drops keeps the last-known
  data with `as_of` from the DROP time (heartbeat 25s/75s; passive handoff of the socket).
  Henry sees only entities exposed to Assist: ABSENT from the exposure list = not exposed (unless
  the list itself failed to load), and hidden / disabled / entity_category / Govee "Segment NNN"
  entities never appear. Room and house fan-out is LIGHTS ONLY because the Basement holds the
  homelab outlets (`switch.homelab_surge_protector_l2..l5`) — "turn off the basement" must never
  cut the servers. `lock`, `alarm_control_panel` and garage covers have no action→service mapping
  anywhere (view-only); don't add one. `unavailable` = offline and is never called; `unknown` is
  NOT offline (plenty of healthy entities report it). The resolver acts only on a clear winner
  with no unmatched words, else asks; a timeout answers "it may still happen", not "failed".
  Media actions (play/pause/next/volume_set) resolve among media players only (`Resolve`
  `:media`): "pause the kitchen" is the kitchen speaker, never the kitchen's lights.
  `HOME_ASSISTANT=false` is still the kill switch; no new env vars. Grep `[home]` / `[toolkit]`.
- **The integration pattern** (spec `docs/superpowers/specs/2026-10-19-toolkits-and-home-v2-design.md`,
  "The integration pattern", 10 rules): a toolkit with curated verbs rather than passthrough,
  resolve the user's words in code not in the model, one call for the common case, a local mirror,
  honest outcomes as first-class results, safety as absent code paths, one greppable log line per
  decision, a fixture eval from a real snapshot, and degrade rather than die. The repos toolkit
  (and any later connector) should follow it; the home kit is the reference implementation.

- **Claude dispatch is a contract, not a call.** Henry starts a job by dispatching the
  `work-issue.yml` workflow on `kalcode/claude-dispatch` with `inputs` `repo`, `issue`, `job_id`
  (plus a top-level `return_run_info: true` beside them); the box reports back by POSTing a
  callback signed with HMAC over the RAW request bytes (`DISPATCH_CALLBACK_SECRET`). Plug.Parsers
  parses first; the HMAC is checked against the cached raw bytes (`AppWeb.CacheBodyReader`)
  before anything is trusted, and the JSON is never re-encoded. Only `conn.body_params` count
  (the query string isn't signed), and a body's `repo`/`issue`, when present, must be the job's.
  Callbacks are idempotent and end states are sticky: `Dispatch.set_status/3` and `claim_notice`
  are race-safe (a no-op once a real end state landed, one notification per job), so the
  watchdog and a late callback can't double-notify or overwrite each other. The `Notifier` starts
  on its own flag, not the forge (the kill switch mustn't silence a running job's end), and on
  boot announces end states from the last 24 h that nobody announced. An AMBIGUOUS dispatch
  outcome (no run info, timeout) leaves the job `queued` rather than `failed` — the run may exist
  and its callback must still be accepted. The watchdog never marks `lost` by age alone, because
  the box runs ONE job at a time and the third queued issue legitimately waits hours: a run still
  waiting/running is left alone; 404 = `lost` ("the run disappeared"); only 24 h of failed reads
  IN A ROW mark it `lost` (the streak's start is `read_error_since` on the row, cleared by a good
  read, so a restart doesn't reset it). With no `run_id`, a `queued` job is `lost` 6 h after it
  was created, a `running` one 6 h after its last callback (`updated_at`). Two forge bases:
  `FORGE_URL` is the API base, the forge's LAN address `http://192.168.50.249:3000`, so API POSTs
  skip Cloudflare's browser check; `FORGE_PUBLIC_URL` (`https://code.clausens.cloud`, defaults to
  `FORGE_URL`) is the base of every link a human opens (ntfy Click, issue/run links,
  `file_issue`'s url). A callback's own `run_url` is stored and preferred over a built one.
  Token and secret come from env only (names in `server/.env.example`). Henry's `FORGE_TOKEN`
  needs **`read:user`** as well as `write:repository` + `write:issue`: Forgejo puts
  `GET /user/repos` (the repo list) behind the *user* scope, so without it every board read is a
  403 (`[dispatch] repo list failed: the forge answered HTTP 403`). Token scopes can't be edited
  in Forgejo — make a new token. The box's `DISPATCH_FORGE_TOKEN` calls no `/user` endpoint and
  stays at `write:repository` + `write:issue`. With the forge set but
  no `DISPATCH_CALLBACK_SECRET`, boot logs a warning and `start_claude` refuses up front (no job,
  no dispatch): every callback would be refused, so a job could never report back.
- **The box (CT 109) and the dispatcher repo** are documented in `homelab/runbooks/claude.md` and
  `kalcode/claude-dispatch` (workflow, runner, `CLAUDE_CODE_OAUTH_TOKEN` and `DISPATCH_FORGE_TOKEN`
  repo secrets). Server-side code here only dispatches and receives callbacks.
- **The repos kit is registered for everyone; the per-user gate is inside the tools.**
  `Repos.enabled?/1` is just `App.Config.forge?()` and `wants?/2` preselects with no user check.
  Each dispatch tool calls `allowed?/1` (`claude_dispatch.ex`) against `CLAUDE_DISPATCH_USERS`
  (unset = nobody); anyone else gets "that's not set up for you" with no forge call. Preselection
  by repo name (`Board.warm/0` loads the names 10 s after boot) is filtered by Board's `@not_topic`
  stop-list plus minimum word/phrase lengths (`@min_word` 6, `@min_phrase` 4), so common words that
  are also repo names don't open the kit.
- **Production logs never carry what someone said.** `App.LogText.said/1` logs content verbatim in dev and test and only its length in prod (`log_speech: false`), because prod logs ship to SigNoz, which the Claude dispatch box can read. Any new log line that prints speech, typed text, a calendar/email title, a memory fact or tool arguments goes through it.

- **The window's size reads 0x0 in `main()` on Android** (no metrics yet). Anything that sizes
  itself before `runApp` must await `settledLogicalSize()` (`orientation_lock.dart`); reading
  the view directly made the Lenovo a "phone": portrait-locked and in the personal role.
- **A wall is a device role, not a user pref** (`lib/device/device_role.dart`, a JSON file on
  the device; tablets default to wall). A wall joins `kiosk: true`, holds the screen on, hides
  the bars, dims 22:00–07:00 at rest, IGNORES the account's Default PTT (PTT closes the mic to
  all but the held button, so a wall in PTT cannot hear "Henry") and powers its own mic on once
  per launch (a phone waits for the power button). Don't "fix" either back to the account's
  defaults; that is #19's per-device split, decided.
- **Household scope follows the BOUND device, never the user.** The Conversation is one per user,
  so a scope stored on it leaked from the wall onto the phone (July's C1). It keeps each
  channel's `%{kiosk, shared}` role and publishes the bound one's scope as its Registry value;
  `App.Conversations.Scope.current(session_id)` reads it from any process (tools, the Gemini
  adapter). Household: bare "remind me" is the household's, Gmail is withheld (declarations AND
  dispatch), and the brain's note rides the user message. `[scope]` logs each change.
- **Ink idle-closes the STT socket after ~3 minutes, and a locked wall sends no audio**, so most
  wakes reconnect. The adapter HOLDS frames pushed while connecting (capped 8 s) and flushes them
  on the 101; dropping them clipped the first words of nearly every wake (`[stt] socket up;
  sending N frames held during the connect`).
- **Ink's turn-end sensitivity is ours to set** (`App.Config :stt_turn_end_threshold`, sent as
  `turn_end_threshold` on the hands-free socket only). At Ink's default 0.3 a mid-sentence
  pause ended the turn, so Henry answered half a sentence and talked over the rest (#42); it is
  0.1 (Cartesia's "Patient" end threshold). Don't raise it back for latency without a listening
  test on the wall. A rejected parameter shows up as `[stt] Ink error`. Speech onset
  (`turn.start`) re-arms the idle relock, as a partial does; without that, a relock landing just
  as the user started talking closed the wall's mic on their first words.

## Testing patterns

- Mox: the text model is `App.TextModelMock` (set_mox_global; `async: false`). TTS/STT/brain-stream use
  **fakes** (`App.Test.Fakes.*`). The fake STT notifies a registered `:fake_stt_observer`
  (`{:fake_stt_started, mode}` on connect, `{:fake_stt_push, _}`, `{:fake_stt_finalize}`) — handy for
  asserting the PTT reconnect/finalize paths. The fake brain has app-env knobs (`:fake_brain_done_ms`,
  `:fake_brain_error`, `:fake_brain_text_deltas`) and notifies `:fake_brain_observer`.
- HTTP adapters stub `Req` via app-env keys: `:weather_req_opts`, `:google_req_opts` (Req.Test plug).
- Home Assistant tests never reach a real HA and are `async: false` (global app env). The
  directory comes from the `:home_assistant_directory` override (a `%Directory{}` or a 0-arity
  fun returning `{:ok, dir}`), usually `App.Test.HomeFixture.directory()`, the sanitized
  real-house snapshot (`with_alias/2` returns its payloads with an alias added, for
  `Directory.build/2`); service calls go through `:home_assistant_req_opts` (a `Req.Test`
  stub). `config/test.exs` sets `start_home_assistant_live: false` and `:home_assistant_watch_ms`
  0. `LiveTest` runs `Live` against a local fake HA (Bandit + WebSock); call
  `App.HomeAssistant.forget_phrases/0` around anything that publishes phrases.
- Pure helpers are exposed `@doc false def` so tests call them directly (e.g. `Stt.Cartesia.route/2`,
  `Calendar.account_matches?/2`, `Gemini.tools_block/1`, `Weather.build_*`).

## Known debt / next

- **Shipped 2026-10-10 (household Jarvis, free-rein session):** Type to Henry (quiet text turns),
  timers, visual cards, the household intercom, trackers, routines, recipes + cook mode, calendar
  heads-ups, the ambient orb face, nightly backups, recipe/tracker/routine shelves in Books,
  background notifications, tappable cook-mode timer pills, cards that survive history replay.
  Live-smoked on an emulator against a sandbox server; the on-device checklist is
  `docs/superpowers/results/2026-10-10-household-jarvis-smoke.md`.

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
