# Deploying Remi to Coolify

A runbook for the **Coolify** (dev/staging) environment at **`your-domain.example.com`**, alongside the
local `localhost:8787` dev environment. Build is a standard Phoenix Elixir release via the
**`Dockerfile`**; data is SQLite on a **persistent volume**; Coolify terminates HTTPS.

## How the two environments coexist

| | Local | Coolify |
|---|---|---|
| URL | `http://localhost:8787` | `https://your-domain.example.com` |
| `MIX_ENV` | `dev` | `prod` (release) |
| DB | `app_dev.db` (repo dir) | `/data/app.db` (persistent volume) |
| OAuth redirect | `http://localhost:8787/auth/google/callback` | `https://your-domain.example.com/auth/google/callback` |

Each environment sends **its own** `redirect_uri`; register **both** in the Google OAuth client and
they never interfere. The prod redirect comes from the `GOOGLE_OAUTH_REDIRECT_URI` env var
(`config/runtime.exs` reads it); local uses the `config/config.exs` default.

> Prod has a **separate, empty database** (the volume). Your local dev users/connections do NOT
> carry over. On first prod login you'll sign in (the first user → becomes the primary), then connect
> your Google accounts fresh from the prod "Google accounts" panel.

## 1. Google Cloud console (one-time)

In the OAuth client used for `GOOGLE_CLIENT_ID`/`SECRET`:
- **Authorized redirect URIs** → add `https://your-domain.example.com/auth/google/callback`
  (keep `http://localhost:8787/auth/google/callback` for local).
- **OAuth consent screen → Authorized domains** → add `example.com` if prompted.
- Gmail/Calendar are restricted/sensitive scopes in **testing** mode → make sure your
  Google accounts are listed as **Test users**. (The domain change doesn't affect this.)

## 2. Coolify application setup

1. **Source:** point the Coolify app at this git repo + the branch you deploy (e.g. `main`).
   Coolify pulls from the **remote**, so the branch must be **pushed**.
2. **Build pack: Docker Compose** — point it at the committed `docker-compose.yml` (it declares the
   service, the `/data` volume, and the env-var passthrough). *Alternatively* use the **Dockerfile**
   build pack — then you must add the `/data` volume yourself in the Persistent Storage UI (step 5).
3. **Port:** the service exposes **4000** (matches `PORT`); Coolify routes the domain to it.
4. **Domain:** `your-domain.example.com` — Coolify provisions the Let's Encrypt cert + reverse-proxies
   (Traefik handles the WebSocket upgrade for voice + LiveView automatically).
5. **Persistent storage (MANDATORY):** with the Compose build pack the `app-data` volume at
   **`/data`** is already declared — Coolify creates it, nothing to add. (Dockerfile build pack: add
   a volume mounted at `/data` in the UI.) Without a persistent volume, **every redeploy wipes the
   database** (users, connections, memory, reminders).

## 3. Environment variables (Coolify → Environment Variables)

Non-secret:
```
PHX_SERVER=true
PHX_HOST=your-domain.example.com
PORT=4000
DATABASE_PATH=/data/app.db
GOOGLE_OAUTH_REDIRECT_URI=https://your-domain.example.com/auth/google/callback
POOL_SIZE=5
```
Secrets (mark as secret in Coolify; never commit these):
```
SECRET_KEY_BASE=<run `mix phx.gen.secret` locally and paste>
GOOGLE_API_KEY=<value>
CARTESIA_API_KEY=<value>
GOOGLE_CLIENT_ID=<value>
GOOGLE_CLIENT_SECRET=<value>
```
(Same secret names as your local `.env` — copy the values over.)

## 4. Deploy

Push the branch → Coolify builds the Dockerfile and starts the container. The image's
**entrypoint** (`bin/docker-entrypoint.sh`) runs on every boot:
1. `mkdir -p` the `DATABASE_PATH` directory (the mounted volume),
2. `bin/migrate` (applies migrations — idempotent),
3. `bin/server` (starts Phoenix).

So the first deploy creates the schema on the fresh volume automatically; later deploys just apply
new migrations.

## Notes / gotchas

- **Runs as root in-container** by design — Coolify bind-mounts the volume root-owned, and the
  default `nobody` user couldn't create `app.db`. Fine for this single-tenant, auth-gated app;
  harden later with `gosu` (chown the volume, then drop privileges) if wanted.
- **WebSocket / `check_origin`:** prod checks the request origin against `PHX_HOST`, so set
  `PHX_HOST=your-domain.example.com` exactly (no scheme/port). The voice socket then connects over `wss`.
- **IPv6 bind:** `config/runtime.exs` binds prod on `{0,0,0,0,0,0,0,0}` (IPv6 any, dual-stack).
  If Coolify health checks can't reach the container, flip it to `{0, 0, 0, 0}` (IPv4) and redeploy.
- **Voice latency:** the mic/TTS audio streams browser↔server; if the Coolify host is a remote VPS,
  expect more round-trip than localhost (the STT/brain/TTS are external API calls either way).
- **Allowlist is compile-time** (`config/config.exs`) — baked into the image. To change who can sign
  in (or your aliases), edit `config.exs` and redeploy.
- **Backups:** the whole DB is the single file at `/data/app.db` — snapshot that volume to back up.
