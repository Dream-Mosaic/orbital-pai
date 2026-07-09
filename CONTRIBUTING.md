# Contributing to Henry

Thanks for your interest! Henry is a low-latency, voice-first personal assistant built in
Elixir/Phoenix. Contributions — bug reports, fixes, features, docs — are welcome.

## Getting set up

**Prerequisites**

- Elixir + Erlang/OTP (see `.tool-versions` / `mix.exs` for the versions the project builds against)
- Node.js (for the JS asset bundle)
- API keys for the external services the assistant uses:
  - **Google Gemini** (`GOOGLE_API_KEY`) — the reflex + brain language models
  - **Cartesia** (`CARTESIA_API_KEY`) — speech-to-text (Ink-2) + text-to-speech (Sonic)
  - **Google OAuth** (`GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET`) — sign-in + the Calendar/Gmail
    connectors (optional if you're not touching those)

**Steps**

```bash
git clone <your-fork>
cd personal-assistant
mix setup                       # deps + DB + assets

cp .env.example .env            # then fill in your keys
# set ALLOWED_USERS in .env to your own Google account(s) — that's the sign-in allowlist

./dev.sh                        # runs the server on PORT (default 8787), tees to log/companion.log
```

Open `http://localhost:8787`. **Read `log/companion.log`** when something misbehaves — it's the
primary diagnostic surface.

## The gate

Before opening a PR, make sure the full gate passes:

```bash
mix precommit
```

`mix precommit` = `compile --warnings-as-errors` + `deps.unlock --unused` + `format` + `test`. If you
touched JS, also run `mix assets.build` and confirm the bundle is clean (there is no JS unit runner —
JS is smoke-verified in the browser).

## Conventions

- **Framework rules** live in `AGENTS.md` (Phoenix v1.8, LiveView, Ecto, HEEx idioms). Please follow
  them.
- Keep the test suite green and the output pristine (no stray warnings).
- Match the style and comment density of the code around what you're changing.
- Prefer small, focused changes with a clear commit message.

## Proposing changes

1. Open an issue first for anything non-trivial, so we can agree on the approach.
2. Fork, branch, and make your change with tests.
3. Run `mix precommit` and make sure it's clean.
4. Open a PR against `main` describing what changed and why.

## A note on scope

Henry is a personal assistant that talks to real external services and can *act* (send email, create
calendar events, etc.). Please be thoughtful with changes that touch tool execution, authentication,
or the turn-taking/barge-in logic — include tests and explain the behavior.

By contributing, you agree that your contributions are licensed under the project's
[MIT License](LICENSE).
