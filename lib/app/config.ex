defmodule App.Config do
  @moduledoc "Per-conversation tunables. Env-overridable later; defaults here."

  defstruct name: "Henry",
            # Per-tier models: smarter for the brain (+ memory summaries), fast for reflex (+ bridges).
            model_brain: "gemini-3.5-flash",
            model_reflex: "gemini-3-flash-preview",
            reflex_thinking: "minimal",
            brain_thinking: "low",
            # voice_id: "1fcd23d0-bf12-4896-8f60-4f21ef5c9b98",   # Austin
            # voice_id: "3e39e9a5-585c-4f5f-bac6-5e4905c51095",   # Cole
            # voice_id: "630ed21c-2c5c-41cf-9d82-10a7fd668370",   # Corey
            # Nolan
            # voice_id: "65209f8e-6140-4a20-b819-3cc2e21da19b",
            # voice_id: "79f8b5fb-2cc8-479a-80df-29f7a7cf1a3e",   # Theo
            # Toby
            voice_id: "3d5ce2fb-e56c-42f0-9ed9-4662484063b4",
            # Cartesia TTS, shared by the reflex HTTP path and the streaming WS path.
            tts_model: "sonic-3.5",
            # 0.6–1.5
            tts_speed: 1.0,
            # 0.5–2.0
            tts_volume: 1.0,
            # neutral, happy, excited, enthusiastic, elated, euphoric, triumphant, amazed, surprised, flirtatious, curious, content, peaceful, serene, calm, grateful, affectionate, trust, sympathetic, anticipation, mysterious, angry, mad, outraged, frustrated, agitated, threatened, disgusted, contempt, envious, sarcastic, ironic, sad, dejected, melancholic, disappointed, hurt, guilty, bored, tired, rejected, nostalgic, wistful, apologetic, hesitant, insecure, confused, resigned, anxious, panicked, alarmed, scared, proud, confident, distant, skeptical, contemplative, determined
            # nil → omit (neutral); else a Cartesia emotion string
            tts_emotion: "content",
            # Cartesia API version: the date we last tested the integration. It's a
            # backwards-compat pin (Cartesia freezes the request/response shape as of this
            # date), NOT a model version — shared by TTS (Sonic) and STT (Ink-2). Bump it to
            # today's date whenever you re-test against the API.
            cartesia_version: "2026-06-24",
            # watchdog backstop: high enough to cover a long streamed answer, low enough
            # to recover a stuck generation.
            turn_max_ms: 45_000,
            # Mic/STT runs at 16k (Ink-2 ingests pcm_s16le @ 16k; higher doesn't help transcription).
            stt_sample_rate: 16_000,
            # Cartesia Ink-2 STT model (native semantic turn detection).
            stt_model: "ink-2",
            # TTS output + browser playback. 44.1k is full-fidelity; drop to 24_000/16_000 to trade
            # quality for bandwidth. Must match the client playback rate (wired from this in the LiveView).
            tts_sample_rate: 24_000,
            jitter_buffer_ms: 150,
            # Enabled tool modules (App.Tools.Tool behaviour).
            tools: [App.Tools.Weather, App.Tools.Reminders, App.Tools.Calendar, App.Tools.Gmail],
            # Google-Search grounding on the brain request (web search). Toggle off if the model
            # ever rejects googleSearch alongside function tools.
            web_search: true,
            # Speak a short canned "bridge" phrase while a slow tool runs (mask the tool-call gap).
            tool_bridges: true,
            # Cache {:ok,_} tool results (ETS, per-tool TTLs) so repeat reads skip the API call.
            tool_cache: true,
            # Pre-compute the reflex on Ink's turn.eager_end prediction so it's ready the instant
            # turn.end confirms (turn.resume cancels). Hands-free only. Off → pure Phase-1 timing.
            eager_reflex: true,
            # :always — the reflex always speaks first (brain audio waits for it).
            # :race — if the brain's first audio lands before the reflex has spoken, skip the
            # reflex (it's latency insurance, not a ritual). Flip after live smoke.
            reflex_mode: :always,
            # Voice-activation wake matching (App.Conversations.WakeWord): attention
            # prefixes ("wake up Henry"), extra accepted name spellings grown from the
            # `[wake] locked drop` log lines, and the fuzzy (Levenshtein<=1) toggle.
            wake_prefixes: ["wake up", "hey", "okay", "ok"],
            wake_aliases: [],
            wake_fuzzy: true,
            # Voice-activation SLEEP commands (App.Conversations.WakeWord.sleep_command?/2):
            # "Henry sleep" / "Henry lock" re-locks him (vs the stop lexicon, which halts but
            # keeps him awake). Same name-trigger + word-boundary discipline as the stop words.
            sleep_words: ["sleep", "lock", "go to sleep", "go back to sleep"],
            # Used to tell the brain how to resolve relative reminder times.
            timezone: "America/Chicago",
            # Default weather location: {lat, lon, label}. 62221 / Belleville, IL.
            weather_home: {38.52, -89.98, "Belleville, IL"}

  @type t :: %__MODULE__{}

  @spec default() :: t()
  def default, do: %__MODULE__{timezone: timezone()}

  @doc """
  The instance timezone — one IANA zone for the whole instance, from the `TIMEZONE` env (wired to
  `:app, :timezone` in config/runtime.exs) and validated against Tzdata. Falls back to
  `"America/Chicago"` when unset or invalid, so a typo'd env can't crash local-time rendering
  (`DateTime.shift_zone!`). Grounds the brain's relative-time resolution and the reminder display.
  """
  @spec timezone() :: String.t()
  def timezone do
    tz = Application.get_env(:app, :timezone, "America/Chicago")
    if valid_zone?(tz), do: tz, else: "America/Chicago"
  end

  defp valid_zone?(tz) when is_binary(tz),
    do: match?({:ok, _}, DateTime.shift_zone(~U[2024-01-01 00:00:00Z], tz))

  defp valid_zone?(_), do: false
end
