# Connectors — Google Calendar & Gmail setup

Henry can read + create **Google Calendar** events and search/read/**send Gmail**. Because these act
on *your* Google account, each person running Henry needs their **own Google Cloud project** and OAuth
client. This is the fiddliest part of self-hosting — follow the steps below.

> You do **not** need this to run Henry. Skip it if you only want voice + weather + reminders + web
> search. The `GOOGLE_API_KEY` (Gemini) is a **separate** thing from the OAuth client here.

## What you'll end up with

- `GOOGLE_CLIENT_ID` + `GOOGLE_CLIENT_SECRET` in your `.env`
- (for a deployed instance) `GOOGLE_OAUTH_REDIRECT_URI` pointing at your domain
- The **Google Calendar API** and **Gmail API** enabled on your project
- Yourself added as a **test user** (or the app published)

## Steps (Google Cloud Console)

1. **Create a project** at <https://console.cloud.google.com/> (or reuse one).

2. **Enable the APIs** — APIs & Services → *Enable APIs and services*, then enable **both**:
   - **Google Calendar API**
   - **Gmail API**

   > ⚠️ If an API isn't enabled, calls 403 with `accessNotConfigured` / `SERVICE_DISABLED` — and it
   > looks like a scope problem when it's really the API being off. Enable both up front.

3. **Configure the OAuth consent screen** — APIs & Services → *OAuth consent screen*:
   - User type: **External**.
   - Add the scopes Henry uses (below).
   - Under **Test users**, add the Google account(s) you'll sign in with.

4. **Create credentials** — APIs & Services → *Credentials* → *Create credentials* → *OAuth client ID*:
   - Application type: **Web application**.
   - **Authorized redirect URIs** — add **both** of these (register the ones you'll use):
     - `http://localhost:8787/auth/google/callback` (local dev — match your `PORT`)
     - `https://YOUR_DOMAIN/auth/google/callback` (a deployed instance)
   - Create, then copy the **Client ID** and **Client secret**.

5. **Put them in `.env`:**
   ```bash
   GOOGLE_CLIENT_ID=...apps.googleusercontent.com
   GOOGLE_CLIENT_SECRET=...
   # deployed instances only — overrides the localhost default:
   # GOOGLE_OAUTH_REDIRECT_URI=https://YOUR_DOMAIN/auth/google/callback
   ```

6. **Connect an account in the app** — open the **Connectors** panel and add a Google account; you'll
   go through Google's consent flow and land back in Henry.

## Scopes Henry requests

| Scope | Used for |
|---|---|
| `https://www.googleapis.com/auth/calendar.readonly` | reading events |
| `https://www.googleapis.com/auth/calendar.events` | creating events |
| `https://www.googleapis.com/auth/gmail.readonly` | searching + reading email |
| `https://www.googleapis.com/auth/gmail.send` | sending email |

## Gotchas (hard-won)

- **Enable both APIs** (see step 2) — the #1 cause of mysterious 403s.
- **`gmail.send` is a *restricted* scope.** In **testing** mode your app stays *unverified*, and
  Google expires refresh tokens after **~7 days** — the account will surface as needing to
  **reconnect**. For steady personal use you either reconnect periodically, or take the app through
  Google's **verification / publishing** (a heavier process). Calendar-only usage doesn't hit this.
- **Incremental consent:** if you connected an account for Calendar *before* adding Gmail, you must
  **reconnect** that account to grant the new Gmail scopes (the existing Calendar grant is retained).
- **Register both redirect URIs** (localhost for dev, your domain for prod) — the flow fails with a
  redirect-mismatch otherwise.
