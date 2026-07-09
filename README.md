# Henry — a naturally-responsive voice assistant

Henry is a low-latency, voice-first personal assistant built in **Elixir/Phoenix**. You talk; it
answers out loud — fast — and it can actually *do things* (calendar, email, reminders, weather, web
search) through a tool-calling brain. It remembers what matters about you across conversations, works
as an installable PWA, and has a "kiosk" wall mode.

<p align="center">
  <img src="docs/screenshots/pai_phone_henry_user_02.png" alt="Henry mid-conversation on a phone" width="300">
</p>

## Screenshots

| Conversation (phone) | Kiosk / wall mode | Powered off |
|---|---|---|
| ![phone](docs/screenshots/pai_phone_henry_user_02.png) | ![kiosk](docs/screenshots/pai_kiosk_henry_01.png) | ![off](docs/screenshots/pai_phone_henry_off_03.png) |

The orb is the light source: it glows **amber** while you speak, **green** while Henry speaks, and the
whole surface breathes with the live audio. Your turns run down an amber rail, Henry's down a green one.

## How it works (the pipeline)

```
mic → Cartesia Ink-2 STT → Conversation (gen_statem) ──► reflex  (instant ~1s filler, Gemini minimal)
                                                     └─► brain   (streaming Gemini → Cartesia TTS → audio)
                                                            └─ tools: weather · reminders · calendar · email · web search
```

- **One vendor for voice** — Cartesia **Ink-2** for speech-to-text (native semantic turn detection)
  and **Sonic** for text-to-speech, over one `CARTESIA_API_KEY`.
- **Reflex + brain split** — an instant short "reflex" masks latency while the streaming "brain"
  composes the real answer (Gemini SSE → Cartesia WebSocket → gapless audio). The reflex even gets a
  **head-start** from Ink's `turn.eager_end` prediction, and the brain's answer text **streams to the
  UI live** (a caption that fills word-by-word, then snaps to formatted markdown).
- **Tools** — the brain calls functions (`App.Tools.*`) inline mid-turn: weather (Open-Meteo),
  reminders (SQLite + scheduler), Google **Calendar** (read + create), **Gmail** (search + read +
  send), and **web search** (Gemini grounding).
- **Memory** — durable profile facts + a rolling summary, auto-extracted, shown/editable in the UI.
- **Turn-taking** — Ink-2's **native semantic endpointing** (a mid-thought pause doesn't cut you off),
  a **push-to-talk** mode (hold a button, via Ink's manual finalize), and **barge-in** ("allow
  interruptions" — talk over Henry and he yields, driven by Ink's `turn.start`).
- **Proactive** — a generic *agenda* system delivers self-initiated turns; reminders fire as spoken,
  polite interjections (speak when idle, queue mid-turn, interject at the next breath).
- **Multi-user** — sign-in is gated by an allowlist; each user sees only their own memory, reminders,
  and connected accounts.

## Run it (dev)

Needs Elixir/Erlang, Node (for asset deps), and API keys.

```bash
cp .env.example .env     # fill in GOOGLE_API_KEY, CARTESIA_API_KEY (STT + TTS), Google OAuth,
                         # and ALLOWED_USERS (the sign-in allowlist — set it to your own account)
mix setup                # deps, DB, assets, npm
./dev.sh                 # loads .env, runs the server, tees output to log/companion.log
```

Open the URL it prints (default `http://localhost:8787`, from `PORT` in `.env`), tap the **power**
button, allow the mic, and speak. (Chrome recommended for Web Audio.)

- **Secrets + config** live in `.env` (gitignored) — never commit them. `ALLOWED_USERS` is JSON; see
  `.env.example` for the format.
- **Google Calendar / Gmail** are optional and need a one-time setup of your *own* Google Cloud
  project (OAuth client + enabling the APIs). See **[docs/connectors.md](docs/connectors.md)** for the
  full walkthrough, then connect accounts from the Connectors panel.

## Deploy

Henry ships as a Docker image and runs behind any reverse proxy / tunnel that supports WebSockets
(e.g. a Cloudflare Tunnel). All secrets + host come from environment variables — nothing is baked into
the image. See `docker-compose.yml` and `docs/deploy-coolify.md` for a reference deployment (SQLite on
a persistent volume, `SECRET_KEY_BASE`, `PHX_HOST`, `ALLOWED_USERS`, etc.).

## Project layout

- `lib/app/conversations/` — the turn engine: `Conversation` (gen_statem), `Policy`, `BrainStream`, `Sessions`.
- `lib/app/adapters/` — external services: `Stt.Cartesia` (Ink-2), `TextModel.Gemini`, `Tts.Cartesia` (Sonic).
- `lib/app/agenda*` — generic self-initiated ("agenda") turns; `lib/app/reminders/` — the reminder producer.
- `lib/app/tools/` — the brain's callable tools (`Tool` behaviour + registry).
- `lib/app/google/` — OAuth + Calendar + Gmail; `lib/app/memory/` — facts/summary/turns.
- `lib/app_web/` — `VoiceChannel`, `ConversationLive`, `GoogleAuthController`.
- `assets/js/voice/` — the `Voice` hook (mic capture, gapless playback, the live orb + caption, push-to-talk).

## Contributing

Contributions are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md) for setup, the test gate
(`mix precommit`), and conventions. Framework idioms live in `AGENTS.md`.

## License

[MIT](LICENSE) © David Clausen
