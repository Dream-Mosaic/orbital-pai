defmodule App.Conversations.Conversation do
  @moduledoc """
  gen_statem shell that drives `App.Conversations.Policy` and executes its effects.

  A turn: the **reflex** is a fast batch call (Gemini minimal → TTS → one clip) that leads
  instantly; the **brain** is a streaming pipeline (`BrainStream`: Gemini SSE → Cartesia WS
  → audio chunks). Brain chunks are buffered until the reflex audio has been sent, then
  flushed + streamed to the client, which plays them back-to-back. The turn completes when
  the audio timeline drains.

  Design rule: callbacks never block. Reflex model/TTS run in `Task.Supervisor.async_nolink`
  tasks; the `BrainStream` is started **unlinked + monitored** so its crash arrives as a
  `:DOWN` instead of taking the session down. Stale results (after a barge-in) are dropped.
  """
  @behaviour :gen_statem

  alias App.Conversations.{Backchannel, Policy, WakeWord}
  alias App.Agenda.Item
  alias App.Config
  require Logger

  # barge-in: how long an armed onset waits for confirming words before it's dropped (abandoned onset)
  @interrupt_window_ms 2_000

  # Spoken when the brain finishes a turn with no text at all (e.g. it ran tools but produced an
  # empty answer). Better a short, honest line than dead air — a re-ask usually succeeds.
  @brain_blank "Sorry, I lost that one — mind asking again?"

  # ---- public API ----
  def start_link(opts) do
    case Keyword.get(opts, :name) do
      nil -> :gen_statem.start_link(__MODULE__, opts, [])
      name -> :gen_statem.start_link(name, __MODULE__, opts, [])
    end
  end

  def endpoint(pid, text), do: :gen_statem.cast(pid, {:stt_endpoint, text})
  def partial(pid, text), do: :gen_statem.cast(pid, {:stt_partial, text})
  def barge_in(pid), do: :gen_statem.cast(pid, :barge_in)

  @doc "Client report: how many ms of this turn's audio actually played before stop_playback."
  def played(pid, ms), do: :gen_statem.cast(pid, {:played, ms})
  def ptt_release(pid), do: :gen_statem.cast(pid, :ptt_release)
  def push_audio(pid, pcm16), do: :gen_statem.cast(pid, {:push_audio, pcm16, self()})
  def set_ptt(pid, enabled), do: :gen_statem.cast(pid, {:set_ptt, enabled})

  @doc "Rebind the outbound client (a rejoining channel). Cancels any linger and sends a state snapshot."
  def set_client(pid, client), do: :gen_statem.cast(pid, {:set_client, client})

  @doc "The bound channel died. Arms the linger stop ONLY if `from` is still the bound client."
  def client_disconnected(pid, from), do: :gen_statem.cast(pid, {:client_disconnected, from})
  def ptt_press(pid), do: :gen_statem.cast(pid, :ptt_press)
  def eager_end(pid, text), do: :gen_statem.cast(pid, {:stt_eager_end, text})
  def resume(pid), do: :gen_statem.cast(pid, {:stt_resume})
  def turn_start(pid), do: :gen_statem.cast(pid, {:stt_turn_start})

  def set_allow_interruptions(pid, enabled),
    do: :gen_statem.cast(pid, {:set_allow_interruptions, enabled})

  def set_voice_activation(pid, enabled),
    do: :gen_statem.cast(pid, {:set_voice_activation, enabled})

  def set_relock_ms(pid, ms), do: :gen_statem.cast(pid, {:set_relock_ms, ms})

  @doc "Reset the in-flight turn/transcript state (used by the per-user clear controls)."
  def clear_memory(server), do: :gen_statem.cast(server, :clear_memory)

  @doc false
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :session_id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient,
      type: :worker
    }
  end

  # ---- gen_statem callbacks ----
  @impl true
  def callback_mode, do: :handle_event_function

  @impl true
  def init(opts) do
    # Trap exits so a linked STT crash/close arrives as an {:EXIT, …} message we can
    # recover from (reconnect) instead of taking the whole session down, and so terminate/3
    # runs on shutdown to clean up the unlinked brain.
    Process.flag(:trap_exit, true)
    config = Keyword.get(opts, :config, Config.default())
    session_id = Keyword.get(opts, :session_id)
    {stt_mod, stt_pid} = maybe_start_stt(session_id, config, :auto)

    if session_id do
      Phoenix.PubSub.subscribe(App.PubSub, "agenda:#{session_id}")
      # pull-on-connect: deliver a morning briefing to a user who opens the app AFTER its ready
      # time (the scheduler's broadcast at that time reached no one). Handled post-init.
      send(self(), :pull_briefing)
    end

    data = %{
      policy: Policy.initial_state(),
      config: config,
      client: Keyword.fetch!(opts, :client),
      session_id: session_id,
      stt_mod: stt_mod,
      stt_pid: stt_pid,
      # reflex model + TTS tasks (ref -> {kind, pid})
      refs: %{},
      updater_ref: nil,
      # the streaming brain (unlinked + monitored) and its not-yet-playable audio
      brain_pid: nil,
      brain_ref: nil,
      brain_buffer: [],
      # a brain pre-warmed at speech onset (turn.start while listening), before any transcript
      # exists: {pid, ref} | nil. Adopted (BrainStream.begin/3) by the next :start_brain effect,
      # or killed by the :prewarm_ttl timer if the turn never materializes.
      prewarm_brain: nil,
      # set once we've fallen back to the batch brain (so we don't loop)
      brain_fallback: false,
      # monotonic ms at which all audio sent so far will have finished playing
      audio_until: nil,
      endpoint_at: nil,
      ttfa: nil,
      ttb: nil,
      # per-turn pushed-audio durations (ms) by source — the denominator for heard-fraction
      reflex_ms: 0,
      brain_ms: 0,
      # a barged answered turn awaiting the client's played report: {attrs, total_reflex_ms, total_brain_ms}
      pending_interrupt_persist: nil,
      transcript: nil,
      # agenda items that fired mid-turn, queued to speak at the next clean turn completion
      pending_agenda: [],
      # when set to {item, mode}, the in-flight turn is a self-initiated agenda turn
      # (canned lead instead of the reflex model; not persisted as conversation)
      agenda_turn: nil,
      reflex_text: nil,
      brain_text: nil,
      # eager_end head-start: a reflex pre-computed from Ink's turn.eager_end prediction.
      # nil = none; :running = Gemini call in flight; {:done, text} = ready. commit_speculative? is
      # set when turn.end arrives while still :running, so the in-flight result is then spoken.
      speculative_reflex: nil,
      commit_speculative?: false,
      # push-to-talk: ptt_mode toggled by the client; holding = button/key down; expecting_finalize =
      # a release-driven finalize is in flight (so its endpoint is honored despite ptt_mode).
      ptt_mode: false,
      holding: false,
      expecting_finalize: false,
      # barge-in: allow_interruptions toggled by the client (like ptt_mode); interrupt_pending? is
      # armed by Ink's turn.start during playback and confirmed by the next partial with real words.
      allow_interruptions: false,
      interrupt_pending?: false,
      ducked?: false,
      # an unanswered request carried forward from a barge-in, folded into the next turn's brain
      pending_request: nil,
      # voice activation (wake-word gate): voice_activation = mode on for this session (the client
      # only enables it in kiosk); locked = currently silent until the assistant name is heard.
      voice_activation: false,
      locked: false,
      # wake-word v2: wake_hit marks "a wake trigger already matched in this listening
      # window" (captions keep stripping); last_ack guards the spoken ack's own echo.
      wake_hit: false,
      last_ack: nil,
      # per-session Lockdown-timeout override (ms) from the user's relock_seconds pref;
      # nil -> fall back to the app-env default (also the test override hook).
      relock_ms: nil
    }

    send_state_snapshot(data)

    {:ok, :running, data}
  end

  defp maybe_start_stt(nil, _config, _mode), do: {nil, nil}

  defp maybe_start_stt(_session_id, config, mode) do
    case Application.get_env(:app, :stt) do
      nil ->
        {nil, nil}

      mod ->
        {:ok, pid} =
          mod.start_link(
            owner: self(),
            mode: mode,
            sample_rate: config.stt_sample_rate,
            model: config.stt_model,
            version: config.cartesia_version
          )

        {mod, pid}
    end
  end

  # Reconnect the STT socket in `mode` (PTT toggles between :auto and :manual, which are
  # different Ink-2 endpoints). Unlink before stopping the old pid so its exit doesn't trip
  # the {:EXIT, stt_pid, _} recovery path mid-swap.
  defp restart_stt(data, mode) do
    data = stop_stt(data)
    {mod, pid} = maybe_start_stt(data.session_id, data.config, mode)
    %{data | stt_mod: mod, stt_pid: pid}
  end

  defp stop_stt(%{stt_pid: pid} = data) when is_pid(pid) do
    Process.unlink(pid)
    if Process.alive?(pid), do: Process.exit(pid, :shutdown)

    # unlink only stops FUTURE link signals; an EXIT that crashed in before we unlinked may
    # already sit in our mailbox. Flush it for this pid so it can't later fall through to the
    # catch-all {:EXIT, _, reason} clause and stop the session after we've swapped stt_pid.
    receive do
      {:EXIT, ^pid, _reason} -> :ok
    after
      0 -> :ok
    end

    %{data | stt_pid: nil}
  end

  defp stop_stt(data), do: data

  # Forward a mic frame to the STT, lazily (re)connecting if it has dropped. No-op without
  # a session. Frames during the brief reconnect are dropped by the adapter until ready.
  defp push_to_stt(_pcm, %{session_id: nil} = data), do: data

  defp push_to_stt(pcm, %{stt_pid: nil} = data) do
    mode = if data.ptt_mode, do: :manual, else: :auto
    {mod, pid} = maybe_start_stt(data.session_id, data.config, mode)
    if pid, do: mod.push(pid, pcm)
    %{data | stt_mod: mod, stt_pid: pid}
  end

  defp push_to_stt(pcm, data) do
    data.stt_mod.push(data.stt_pid, pcm)
    data
  end

  # ---- casts (public API + STT process) ----
  @impl true
  def handle_event(:cast, {:stt_partial, t}, _s, data), do: handle_partial(t, data)
  def handle_event(:cast, {:stt_endpoint, t}, _s, data), do: handle_endpoint(t, data)
  def handle_event(:cast, {:stt_eager_end, t}, _s, data), do: handle_eager_end(t, data)
  def handle_event(:cast, {:stt_resume}, _s, data), do: handle_resume(data)
  def handle_event(:cast, {:stt_turn_start}, _s, data), do: handle_turn_start(data)

  def handle_event(:cast, :barge_in, _s, data) do
    Logger.info("[turn] ⏹ barge_in (during #{data.policy.phase})")
    barge_in_feed(on_barge_in(data))
  end

  # Client report of how much of the current turn's audio actually played (arrives right after
  # stop_playback). Only meaningful while a barged answered turn is stashed awaiting it.
  def handle_event(:cast, {:played, ms}, _s, %{pending_interrupt_persist: {_, _, _}} = data),
    do:
      {:keep_state, flush_interrupt_persist(data, {:played, ms}),
       [{{:timeout, :interrupt_persist}, :infinity, :cancel}]}

  def handle_event(:cast, {:played, _ms}, _s, data), do: {:keep_state, data}

  def handle_event(
        :cast,
        :ptt_release,
        _s,
        %{policy: %{phase: :listening}, stt_mod: mod, stt_pid: pid} = data
      )
      when is_pid(pid) do
    mod.finalize(pid)
    {:keep_state, %{data | holding: false, expecting_finalize: true}}
  end

  def handle_event(:cast, :ptt_release, _s, _data), do: :keep_state_and_data

  def handle_event(:cast, {:set_ptt, enabled}, _s, data) do
    # Auto and manual are different Ink-2 endpoints, so changing PTT reconnects the STT socket
    # in the matching mode. Skip the reconnect (and its brief deaf window) on a redundant toggle.
    # On a real change, drop any in-flight auto-mode speculative reflex so a stale head-start
    # can't leak into the PTT turn (the manual socket never emits eager_end to refresh it).
    data =
      if data.ptt_mode == enabled,
        do: data,
        else:
          data
          |> cancel_speculative_reflex()
          |> restart_stt(if(enabled, do: :manual, else: :auto))

    {:keep_state, %{data | ptt_mode: enabled, holding: false, expecting_finalize: false}}
  end

  def handle_event(:cast, {:set_allow_interruptions, enabled}, _s, data),
    do: {:keep_state, %{data | allow_interruptions: enabled}}

  # Idempotent on a redundant "on" (the client re-pushes this on every channel (re)join): don't
  # re-lock or re-notify if voice activation is already on — that would silence the user mid-turn
  # on a socket reconnect.
  def handle_event(:cast, {:set_voice_activation, true}, _s, %{voice_activation: true} = data),
    do: {:keep_state, data}

  def handle_event(:cast, {:set_voice_activation, enabled}, _s, data) do
    data = %{data | voice_activation: enabled, locked: enabled}
    notify_locked(data)
    actions = if enabled, do: [], else: [{{:timeout, :relock}, :infinity, :cancel}]
    {:keep_state, data, actions}
  end

  def handle_event(:cast, {:set_relock_ms, ms}, _s, data) when is_integer(ms) and ms > 0,
    do: {:keep_state, %{data | relock_ms: ms}}

  def handle_event(:cast, {:set_relock_ms, _ms}, _s, data), do: {:keep_state, data}

  def handle_event(:cast, {:set_client, client}, _s, data) do
    data = %{data | client: client}
    send_state_snapshot(data)
    {:keep_state, data, [{{:timeout, :client_linger}, :infinity, :cancel}]}
  end

  # Only the CURRENTLY bound channel arms the linger — a stale channel (another device took
  # over via set_client) terminating must not schedule the death of a session in active use.
  def handle_event(:cast, {:client_disconnected, from}, _s, %{client: from} = data) do
    Logger.info("[conn] client gone — lingering #{linger_ms()}ms for a rebind")
    {:keep_state, data, [{{:timeout, :client_linger}, linger_ms(), :expire}]}
  end

  def handle_event(:cast, {:client_disconnected, _from}, _s, data), do: {:keep_state, data}

  def handle_event({:timeout, :client_linger}, :expire, _s, data) do
    Logger.info("[conn] linger expired with no rebind — stopping the session")
    {:stop, :normal, data}
  end

  def handle_event(:cast, :clear_memory, _s, data),
    do: {:keep_state, reset_turn_fields(data)}

  # PTT press while listening: just mark the button held (start of a fresh utterance).
  def handle_event(:cast, :ptt_press, _s, %{ptt_mode: true, policy: %{phase: :listening}} = data),
    do: {:keep_state, %{data | holding: true, expecting_finalize: false}}

  # PTT press while Henry is still speaking/thinking = take the floor. The button press is a
  # deliberate "talk now" (no echo risk like auto-mode), so it barges in regardless of
  # allow_interruptions — dropping Henry's audio and returning to :listening so the release-finalize
  # lands and the held speech becomes its own turn, instead of orphaning in the manual STT buffer
  # (which is what merged "previous + current" speech onto a later release).
  def handle_event(:cast, :ptt_press, _s, %{ptt_mode: true} = data) do
    Logger.info("[turn] ⏹ PTT barge-in (press during #{data.policy.phase})")
    barge_in_feed(on_barge_in(%{data | holding: true, expecting_finalize: false}))
  end

  def handle_event(:cast, :ptt_press, _s, _data), do: :keep_state_and_data

  def handle_event(:cast, {:push_audio, pcm, from}, _s, %{client: from} = data),
    do: {:keep_state, push_to_stt(pcm, data)}

  # a frame from a channel that is no longer the bound client (stale tab/device) — drop it
  def handle_event(:cast, {:push_audio, _pcm, _from}, _s, data), do: {:keep_state, data}

  # ---- STT process: transcripts + lifecycle via plain send/2 ----
  def handle_event(:info, {:stt_partial, t}, _s, data), do: handle_partial(t, data)
  def handle_event(:info, {:stt_endpoint, t}, _s, data), do: handle_endpoint(t, data)
  def handle_event(:info, {:stt_eager_end, t}, _s, data), do: handle_eager_end(t, data)
  def handle_event(:info, {:stt_resume}, _s, data), do: handle_resume(data)
  def handle_event(:info, {:stt_turn_start}, _s, data), do: handle_turn_start(data)
  def handle_event(:info, :stt_ready, _s, data), do: {:keep_state, data}
  def handle_event(:info, {:stt_error, _reason}, _s, data), do: {:keep_state, data}

  # The linked STT exited — a clean Ink close (idle) or a transient error. Drop the
  # pid; the next mic frame reconnects (push_to_stt). Never go permanently deaf, never die.
  def handle_event(:info, {:EXIT, pid, reason}, _s, %{stt_pid: pid} = data) when is_pid(pid) do
    Logger.info("[stt] exited (#{inspect(reason)}); reconnecting on next audio frame")
    {:keep_state, %{data | stt_pid: nil}}
  end

  # any other linked exit is the supervisor/parent telling us to stop
  def handle_event(:info, {:EXIT, _pid, reason}, _s, data), do: {:stop, reason, data}

  # ---- timers ----
  def handle_event({:timeout, :watchdog}, :watchdog, _s, data) do
    Logger.warning("[turn] ⚠ watchdog fired — turn aborted (phase #{data.policy.phase})")
    feed(:watchdog, data)
  end

  def handle_event({:timeout, :turn_done}, :drained, _s, data), do: feed(:drained, data)

  def handle_event({:timeout, :interrupt_pending}, :expire, _s, data),
    do: {:keep_state, unduck(%{data | interrupt_pending?: false})}

  # No played report arrived within the fallback window — persist the full (untruncated) text,
  # never worse than the old immediate-persist behavior.
  def handle_event({:timeout, :interrupt_persist}, :flush, _s, data),
    do: {:keep_state, flush_interrupt_persist(data, :full)}

  # An unused prewarm outlived its TTL (the user never followed up) — kill it, don't leak the
  # Cartesia WS or Gemini task forever.
  def handle_event({:timeout, :prewarm_ttl}, :expire, _s, %{prewarm_brain: {pid, ref}} = data) do
    Process.demonitor(ref, [:flush])
    if Process.alive?(pid), do: Process.exit(pid, :shutdown)
    {:keep_state, %{data | prewarm_brain: nil}}
  end

  def handle_event({:timeout, :prewarm_ttl}, :expire, _s, data), do: {:keep_state, data}

  def handle_event({:timeout, :relock}, :relock, _s, %{voice_activation: false} = data),
    do: {:keep_state, data}

  # Never lock mid-turn: defer (re-arm) and check again after the turn ends.
  def handle_event({:timeout, :relock}, :relock, _s, %{policy: %{phase: phase}} = data)
      when phase != :listening,
      do: {:keep_state, data, [relock_action(data)]}

  def handle_event({:timeout, :relock}, :relock, _s, data) do
    data = %{data | locked: true}
    Logger.info("[wake] relocked (idle)")
    notify_locked(data)
    {:keep_state, data}
  end

  # ---- streaming brain messages ----
  def handle_event(:info, {:brain_audio, pcm}, _s, %{policy: %{reflex_sent: true}} = data),
    do: {:keep_state, push_audio_chunk(:brain, pcm, data)}

  def handle_event(:info, {:brain_audio, pcm}, _s, data) do
    data = %{data | brain_buffer: [pcm | data.brain_buffer]}

    if data.config.reflex_mode == :race and data.policy.phase == :awaiting_reflex do
      Logger.info("[turn] brain won the race — skipping the reflex")
      feed(:brain_won, data)
    else
      {:keep_state, data}
    end
  end

  # Live caption: stream each brain text delta to the client as Gemini generates it (ahead of the
  # spoken audio). Only while a turn is live — a stale delta from an abandoned/barged turn (phase
  # back to :listening) is dropped, mirroring the {:brain_done, _} guard below.
  def handle_event(:info, {:brain_text, delta}, _s, %{policy: %{phase: phase}} = data)
      when phase != :listening do
    send(data.client, {:to_client, {:brain_delta, delta}})
    {:keep_state, data}
  end

  def handle_event(:info, {:brain_text, _delta}, _s, data), do: {:keep_state, data}

  # Live tool-call chip: mirror the audio tool-bridge filler with a visual "⚙ checking your
  # calendar…" line as each tool call is announced. Only while a turn is live — a stale call
  # from an abandoned/barged turn (phase back to :listening) is dropped, same as brain_text.
  def handle_event(:info, {:brain_tool_call, name}, _s, %{policy: %{phase: phase}} = data)
      when phase != :listening do
    send(data.client, {:to_client, {:tool_call, name}})
    {:keep_state, data}
  end

  def handle_event(:info, {:brain_tool_call, _name}, _s, data), do: {:keep_state, data}

  # The brain finished with no ANSWER text — don't go silent. Substitute a canned line ONCE
  # (guarded by brain_fallback) so the user always hears a reply and knows to retry. NOTE: we key
  # off the answer text being blank, NOT off ttb — a tool "bridge" filler ("let me check your
  # calendar") plays first and sets ttb, so an is_nil(ttb) guard would wrongly treat a bridge-then-
  # empty turn as "already answered" and let the silence through (the prod bug).
  def handle_event(:info, {:brain_done, text}, _s, %{policy: %{phase: phase}} = data)
      when phase != :listening and not data.brain_fallback do
    if blank?(text) do
      Logger.warning("[turn] brain produced no answer text — speaking a canned line, not silence")
      # clear_brain demonitors + flushes the finished brain's DOWN so it can't double-finish the
      # turn; brain_fallback guards against a second substitution from the canned line's own done.
      {:keep_state, spawn_canned_brain(@brain_blank, %{clear_brain(data) | brain_fallback: true})}
    else
      Logger.info("[turn] brain: #{inspect(text)}")
      send(data.client, {:to_client, {:speak_start, :brain, text}})
      feed(:brain_done, clear_brain(%{data | brain_text: text}))
    end
  end

  def handle_event(:info, {:brain_done, text}, _s, %{policy: %{phase: phase}} = data)
      when phase != :listening do
    Logger.info("[turn] brain: #{inspect(text)}")
    send(data.client, {:to_client, {:speak_start, :brain, text}})
    feed(:brain_done, clear_brain(%{data | brain_text: text}))
  end

  def handle_event(:info, {:brain_error, reason}, _s, %{policy: %{phase: phase}} = data)
      when phase != :listening do
    Logger.warning("[turn] brain stream error: #{inspect(reason)}")
    brain_failed(clear_brain(data))
  end

  # stale brain messages from an abandoned turn (after barge-in/complete) -> ignore
  def handle_event(:info, {:brain_done, _text}, _s, data), do: {:keep_state, data}
  def handle_event(:info, {:brain_error, _reason}, _s, data), do: {:keep_state, data}

  # ---- out-of-band agenda delivery ----
  # An agenda item (fired reminder, briefing, follow-up…) is delivered as a self-initiated
  # turn (item lead + brain fulfillment). :when_idle items start now when listening and queue
  # otherwise; :after_next_turn items always queue (first-interaction delivery). Expired items
  # are dropped at every entry point. The LiveView panel listens on the reminders topic
  # independently — this path is speech-only.
  def handle_event(:info, {:agenda_due, %Item{} = item}, _s, data) do
    cond do
      App.Agenda.expired?(item) ->
        Logger.info("[agenda] expired, dropped: #{item.kind}")
        {:keep_state, data}

      briefing_duplicate?(item, data) ->
        Logger.info("[agenda] briefing already pending/in-flight; ignoring duplicate")
        {:keep_state, data}

      item.deliver == :when_idle and data.policy.phase == :listening ->
        start_agenda_turn(item, :idle, data)

      true ->
        Logger.info("[agenda] queued (phase=#{data.policy.phase}): #{item.kind}")
        {:keep_state, %{data | pending_agenda: [item | data.pending_agenda]}}
    end
  end

  # pull-on-connect: on start, if a morning briefing is due for this session's user, inject the
  # same {:agenda_due, item} the scheduler would have broadcast (rides the normal delivery path).
  def handle_event(:info, :pull_briefing, _s, %{session_id: sid} = data) do
    case App.Agenda.Briefing.pull(sid) do
      %Item{} = item -> send(self(), {:agenda_due, item})
      _ -> :ok
    end

    {:keep_state, data}
  end

  # A queued item handed back after a turn completed. Idle now -> interject; a new turn
  # already started -> re-queue for the next completion.
  def handle_event(:info, {:deliver_agenda, %Item{} = item}, _s, data) do
    cond do
      App.Agenda.expired?(item) ->
        Logger.info("[agenda] expired, dropped: #{item.kind}")
        {:keep_state, data}

      data.policy.phase == :listening ->
        start_agenda_turn(item, :interjected, data)

      true ->
        {:keep_state, %{data | pending_agenda: [item | data.pending_agenda]}}
    end
  end

  # the brain process died before signalling done
  def handle_event(:info, {:DOWN, ref, :process, _pid, reason}, _s, %{brain_ref: ref} = data) do
    Logger.warning("[turn] brain stream down: #{inspect(reason)}")
    brain_failed(%{data | brain_pid: nil, brain_ref: nil})
  end

  # a pre-warmed (not yet adopted) brain died on its own — just drop the slot; nothing was
  # waiting on it, so this is not a turn failure. Must precede the generic {:DOWN, …} catch-all.
  def handle_event(
        :info,
        {:DOWN, ref, :process, _pid, _reason},
        _s,
        %{prewarm_brain: {_p, ref}} = data
      ),
      do: {:keep_state, %{data | prewarm_brain: nil}}

  # ---- reflex task result / crash ----
  def handle_event(:info, {ref, result}, _s, %{refs: refs} = data) when is_map_key(refs, ref) do
    Process.demonitor(ref, [:flush])
    {{kind, _pid}, refs} = Map.pop(refs, ref)
    handle_reflex_result(kind, result, %{data | refs: refs})
  end

  def handle_event(:info, {:DOWN, ref, :process, _pid, _reason}, _s, %{refs: refs} = data)
      when is_map_key(refs, ref) do
    {{kind, _pid}, refs} = Map.pop(refs, ref)
    handle_reflex_down(kind, %{data | refs: refs})
  end

  # ---- memory updater task (single-flight) ----
  def handle_event(:info, {ref, _result}, _s, %{updater_ref: ref} = data) do
    Process.demonitor(ref, [:flush])
    {:keep_state, %{data | updater_ref: nil}}
  end

  def handle_event(:info, {:DOWN, ref, :process, _pid, _reason}, _s, %{updater_ref: ref} = data),
    do: {:keep_state, %{data | updater_ref: nil}}

  # ---- stale / unknown ----
  def handle_event(:info, {ref, _result}, _s, data) when is_reference(ref),
    do: {:keep_state, data}

  def handle_event(:info, {:DOWN, _ref, :process, _pid, _reason}, _s, data),
    do: {:keep_state, data}

  def handle_event(:info, _msg, _s, data), do: {:keep_state, data}

  # ---- reflex task results ----
  defp handle_reflex_result(:reflex_model, {:ok, text}, data) do
    Logger.info("[turn] reflex: #{inspect(text)}")
    feed({:reflex_ready, text}, %{data | reflex_text: text})
  end

  defp handle_reflex_result(:reflex_model, {:error, _}, data),
    do: reflex_fallback(data)

  defp handle_reflex_result(:reflex_tts, {:ok, pcm}, data),
    do: feed(:reflex_sent, push_audio_chunk(reflex_source(data), pcm, data))

  defp handle_reflex_result(:reflex_tts, {:error, _}, data),
    do: feed(:reflex_sent, data)

  # Speculative reflex completed. If the turn already endpointed and is waiting on it
  # (commit_speculative?), speak it now; otherwise hold it ready until endpoint.
  defp handle_reflex_result(:speculative_reflex, {:ok, text}, %{commit_speculative?: true} = data) do
    Logger.info("[turn] reflex (eager head-start): #{inspect(text)}")

    feed(
      {:reflex_ready, text},
      %{data | speculative_reflex: nil, commit_speculative?: false, reflex_text: text}
    )
  end

  defp handle_reflex_result(:speculative_reflex, {:ok, text}, data),
    do: {:keep_state, %{data | speculative_reflex: {:done, text}}}

  defp handle_reflex_result(
         :speculative_reflex,
         {:error, _},
         %{commit_speculative?: true} = data
       ),
       do: reflex_fallback(%{data | speculative_reflex: nil, commit_speculative?: false})

  defp handle_reflex_result(:speculative_reflex, {:error, _}, data),
    do: {:keep_state, %{data | speculative_reflex: nil}}

  defp handle_reflex_down(:reflex_model, data), do: reflex_fallback(data)
  defp handle_reflex_down(:reflex_tts, data), do: feed(:reflex_sent, data)

  defp handle_reflex_down(:speculative_reflex, %{commit_speculative?: true} = data),
    do: reflex_fallback(%{data | speculative_reflex: nil, commit_speculative?: false})

  defp handle_reflex_down(:speculative_reflex, data),
    do: {:keep_state, %{data | speculative_reflex: nil}}

  defp reflex_fallback(data) do
    text = "Hm, go on?"
    feed({:reflex_ready, text}, %{data | reflex_text: text})
  end

  # The streaming brain failed (e.g. Cartesia WS unavailable). Fall back ONCE to the
  # batch brain: Gemini (text) + Cartesia HTTP (audio). The batch path resends
  # `{:brain_audio, _}` / `{:brain_done, _}`, so the text shows even if TTS is also down
  # (degrade to text instead of silence). If the brain already produced audio, just finish.
  # NOTE: the batch path (`Gemini.generate/3`) has NO tools and NO time injection — so a
  # tool request (e.g. "remind me at 5pm") in this rare fallback degrades to "can't do that"
  # rather than calling a tool. Acceptable for an error path; revisit if fallbacks get common.
  defp brain_failed(%{brain_fallback: false, ttb: nil} = data) do
    Logger.info("[turn] brain stream failed — falling back to the batch brain")
    {:keep_state, spawn_brain_fallback(%{data | brain_fallback: true})}
  end

  defp brain_failed(data), do: feed(:brain_done, data)

  # Start a fresh BrainStream with a transcript already in hand (no prewarm to adopt, or the
  # prewarm was unusable/refused). Mirrors what run_effect({:start_brain, _}, _) used to do
  # unconditionally before prewarm adoption existed.
  defp cold_start_brain(data, recent?) do
    {:ok, pid} =
      brain_stream_mod().start(
        owner: self(),
        transcript: data.transcript,
        session_id: data.session_id,
        recent_context: recent?,
        config: data.config
      )

    {pid, Process.monitor(pid), data}
  end

  defp spawn_brain_fallback(data) do
    cfg = data.config
    sid = data.session_id
    transcript = data.transcript
    me = self()

    Task.Supervisor.start_child(App.Conversations.TaskSup, fn ->
      ctx = if sid, do: App.Memory.context(sid), else: %{}
      opts = [tier: :brain, config: cfg, thinking: cfg.brain_thinking]

      case text_model().generate(transcript, ctx, opts) do
        {:ok, text} ->
          case tts().synthesize(text, tts_opts(cfg)) do
            {:ok, pcm} -> send(me, {:brain_audio, pcm})
            # TTS down too — still send the text so the UI shows the answer.
            {:error, _} -> :ok
          end

          send(me, {:brain_done, text})

        {:error, _} ->
          send(me, {:brain_error, :fallback_failed})
      end
    end)

    data
  end

  # Speak a fixed canned line as the brain reply (no model call): synthesize audio then re-enter
  # the normal brain_done path with real text. brain_fallback is already set by the caller, so the
  # resulting non-blank {:brain_done, _} can't loop back into another substitution.
  defp spawn_canned_brain(text, data) do
    cfg = data.config
    me = self()

    Task.Supervisor.start_child(App.Conversations.TaskSup, fn ->
      case tts().synthesize(text, tts_opts(cfg)) do
        {:ok, pcm} -> send(me, {:brain_audio, pcm})
        {:error, _} -> :ok
      end

      send(me, {:brain_done, text})
    end)

    data
  end

  defp blank?(text), do: not is_binary(text) or String.trim(text) == ""

  # Live captions + wake handling. Clause order is load-bearing:
  #   1) voice-activation, mid-playback: the SAFETY STOP ("Henry stop") always wins —
  #      regardless of ABI and regardless of locked. While locked, it is the ONLY
  #      interrupt (TV noise must never confirm an ABI interruption).
  #   2) locked + listening: partials are silent until a wake trigger lands; then unlock
  #      immediately (feedback mid-sentence) and caption the STRIPPED remainder.
  #   3) after a wake in this window: keep stripping captions (partials are cumulative).
  #   4/5) the pre-existing ABI confirm + plain paths, unchanged in behavior.
  defp handle_partial(t, %{voice_activation: true, policy: %{phase: phase}} = data)
       when phase != :listening do
    cond do
      sleep_stop?(t, data.config) ->
        Logger.info(~s|[wake] sleep: "#{t}"|)
        # halt + re-lock (vs the safety stop below, which halts but stays awake).
        data = lock_now(%{data | interrupt_pending?: false})
        barge_in_feed(%{on_barge_in(data) | pending_request: nil})

      safety_stop?(t, data.config) ->
        Logger.info(~s|[wake] safety stop: "#{t}"|)

        # wake_hit so the rest of this breath's cumulative partials caption the STRIPPED remainder.
        data = %{data | wake_hit: true, interrupt_pending?: false}
        data = if data.locked, do: unlock(data), else: data
        # A stop is a discard, not a follow-up: null any carried-forward request so it can't fold
        # into the next turn's brain prompt. (Normal ABI barge-in carry-forward is untouched.)
        barge_in_feed(%{on_barge_in(data) | pending_request: nil})

      data.locked ->
        :keep_state_and_data

      data.interrupt_pending? ->
        confirm_interrupt(t, data)

      true ->
        :keep_state_and_data
    end
  end

  defp handle_partial(t, %{voice_activation: true, locked: true} = data) do
    case WakeWord.match(t, data.config) do
      :none ->
        :keep_state_and_data

      {:wake, rest} ->
        Logger.info(~s|[wake] unlocked by partial: "#{t}"|)
        data = unlock(%{data | wake_hit: true})
        if rest != "", do: send(data.client, {:to_client, {:partial, rest}})
        {:keep_state, data, [relock_action(data)]}
    end
  end

  defp handle_partial(t, %{voice_activation: true, wake_hit: true} = data) do
    case WakeWord.match(t, data.config) do
      {:wake, rest} ->
        if rest != "" and data.policy.phase == :listening,
          do: send(data.client, {:to_client, {:partial, rest}})

        feed({:partial, t}, data)

      :none ->
        handle_plain_partial(t, data)
    end
  end

  defp handle_partial(t, %{interrupt_pending?: true} = data), do: confirm_interrupt(t, data)

  defp handle_partial(t, data), do: handle_plain_partial(t, data)

  # Classification-driven decide: noise keeps waiting (ducked), a backchannel restores the
  # volume but keeps the window live (cumulative partials can still escalate), real speech
  # yields. stop_playback resets the client gain, so no unduck is needed on the barge path.
  defp confirm_interrupt(t, data) do
    case Backchannel.classify(t) do
      :interrupt ->
        Logger.info("[turn] ⏹ barge-in confirmed by interrupting speech: #{inspect(t)}")
        barge_in_feed(on_barge_in(%{data | interrupt_pending?: false, ducked?: false}))

      :backchannel ->
        Logger.info("[turn] ~ backchannel (#{inspect(t)}) — continuing")
        data = unduck(data)
        {:keep_state, data}

      :noise ->
        :keep_state_and_data
    end
  end

  defp unduck(%{ducked?: true} = data) do
    send(data.client, {:to_client, :unduck})
    %{data | ducked?: false}
  end

  defp unduck(data), do: data

  defp handle_plain_partial(t, data) do
    if data.ptt_mode and not data.holding do
      :keep_state_and_data
    else
      if data.policy.phase == :listening, do: send(data.client, {:to_client, {:partial, t}})
      feed({:partial, t}, data)
    end
  end

  # A wake trigger whose remainder begins with a command word ("Henry stop") = the safety stop.
  defp safety_stop?(t, cfg) do
    case WakeWord.match(t, cfg) do
      {:wake, rest} -> WakeWord.command_rest(rest) != :none
      :none -> false
    end
  end

  # A wake trigger whose remainder is a sleep command ("Henry sleep" / "Henry lock").
  defp sleep_stop?(t, cfg) do
    case WakeWord.match(t, cfg) do
      {:wake, rest} -> WakeWord.sleep_command?(rest, cfg)
      :none -> false
    end
  end

  # In PTT mode the manual socket only endpoints via a release finalize (expecting_finalize);
  # any other endpoint is ignored. Hands-free (auto) endpoints on Ink's turn.end as normal.
  defp handle_endpoint(t, data) do
    cond do
      data.ptt_mode and not data.expecting_finalize ->
        :keep_state_and_data

      data.voice_activation ->
        handle_gated_endpoint(t, %{data | expecting_finalize: false, holding: false})

      true ->
        feed({:endpoint, t}, %{data | expecting_finalize: false, holding: false})
    end
  end

  # Voice-activation endpoint routing (spec: voice-activation-v2). The wake trigger is
  # stripped wherever it appears (locked or not); a locked utterance without one is
  # dropped + LOGGED — the log line is the evidence trail for growing `wake_aliases`.
  defp handle_gated_endpoint(t, data) do
    case {WakeWord.match(t, data.config), data.locked} do
      {:none, true} ->
        Logger.info(~s|[wake] locked drop: "#{t}"|)
        {:keep_state, %{data | wake_hit: false}}

      {:none, false} ->
        if ack_echo?(t, data),
          do: {:keep_state, data},
          else: feed({:endpoint, t}, %{data | wake_hit: false})

      {{:wake, rest}, _} ->
        if WakeWord.sleep_command?(rest, data.config) do
          # "Henry sleep" / "Henry lock": go silent, no turn, no unlock flicker.
          Logger.info(~s|[wake] sleep: "#{t}"|)
          {:keep_state, lock_now(%{data | wake_hit: false})}
        else
          data = if data.locked, do: unlock(data), else: data
          route_wake_rest(rest, %{data | wake_hit: false})
        end
    end
  end

  # After the trigger: bare wake -> instant ack (no turn); a leading command word means
  # the safety stop already acted on the partial -> swallow it (but answer any tail);
  # otherwise run the stripped remainder as the turn.
  defp route_wake_rest(rest, data) do
    case {blank?(rest), WakeWord.command_rest(rest)} do
      {true, _} -> {:keep_state, speak_ack(data), [relock_action(data)]}
      {false, {:command, ""}} -> {:keep_state, data, [relock_action(data)]}
      {false, {:command, tail}} -> feed({:endpoint, tail}, data)
      {false, :none} -> feed({:endpoint, rest}, data)
    end
  end

  defp unlock(data) do
    data = %{data | locked: false}
    notify_locked(data)
    data
  end

  # Re-lock (the SLEEP command): go silent until the next "wake up Henry". If already locked,
  # just clear wake_hit (no redundant notify). A sleep is a discard, so drop any pending request.
  defp lock_now(%{locked: true} = data), do: %{data | wake_hit: false, pending_request: nil}

  defp lock_now(data) do
    data = %{data | locked: true, wake_hit: false, pending_request: nil}
    notify_locked(data)
    data
  end

  # Spoken for a bare wake ("Henry." / "wake up Henry"): instant, varied, no model call.
  @acks ["Yeah?", "Hm?", "Mm?", "Go on."]
  @ack_echo_window_ms 3_000

  # Instant ack: caption + direct TTS -> client. Deliberately NOT a turn — no reflex/brain,
  # no push_audio_chunk (audio_until untouched), nothing persisted.
  defp speak_ack(data) do
    ack = Enum.random(@acks)
    client = data.client
    cfg = data.config
    send(client, {:to_client, {:speak_start, :reflex, ack}})

    Task.Supervisor.start_child(App.Conversations.TaskSup, fn ->
      case tts().synthesize(ack, tts_opts(cfg)) do
        {:ok, pcm} -> send(client, {:to_client, {:audio, :reflex, pcm}})
        {:error, _} -> :ok
      end
    end)

    %{data | last_ack: {ack, System.monotonic_time(:millisecond)}}
  end

  # Henry's own just-spoken ack, transcribed back through the mic (echo), must not start
  # a self-turn: swallow an endpoint that equals the ack text within the guard window.
  defp ack_echo?(t, %{last_ack: {ack, at}}) do
    System.monotonic_time(:millisecond) - at <= @ack_echo_window_ms and
      squash(t) == squash(ack)
  end

  defp ack_echo?(_t, _data), do: false

  defp squash(s), do: s |> String.downcase() |> String.replace(~r/[^\p{L}\p{N}]+/u, "")

  defp relock_action(data), do: {{:timeout, :relock}, relock_ms(data), :relock}

  # Ink predicts the user is done (turn.eager_end) — pre-compute the reflex now so it's ready the
  # instant turn.end confirms. Silent until then; turn.resume cancels it. Hands-free only;
  # gated by the eager_reflex dial. One speculative reflex per listening window. With voice
  # activation on, the eager transcript may still carry the blob+trigger prefix — strip it.
  defp handle_eager_end(t, data) do
    if data.config.eager_reflex and data.policy.phase == :listening and not data.ptt_mode and
         is_nil(data.speculative_reflex) and not (data.voice_activation and data.locked) do
      t = strip_wake(t, data)
      {:keep_state, spawn_speculative_reflex(t, %{data | speculative_reflex: :running})}
    else
      :keep_state_and_data
    end
  end

  defp strip_wake(t, %{voice_activation: true} = data) do
    case WakeWord.match(t, data.config) do
      {:wake, rest} when rest != "" -> rest
      _ -> t
    end
  end

  defp strip_wake(t, _data), do: t

  defp handle_resume(data) do
    data = if data.speculative_reflex, do: cancel_speculative_reflex(data), else: data
    {:keep_state, %{data | interrupt_pending?: false}}
  end

  # Ink speech-onset during playback with interruptions on: duck the audio instantly and arm
  # the confirmation window (duck-then-decide). Skipped while wake-locked — locked mode only
  # honors the safety stop, and TV noise must not dip the volume every few seconds.
  defp handle_turn_start(%{allow_interruptions: true, policy: %{phase: phase}} = data)
       when phase != :listening do
    if data.voice_activation and data.locked do
      {:keep_state, data}
    else
      Logger.info("[turn] ◉ turn.start during #{phase} — ducked, awaiting words")
      send(data.client, {:to_client, :duck})

      {:keep_state, %{data | interrupt_pending?: true, ducked?: true},
       [{{:timeout, :interrupt_pending}, @interrupt_window_ms, :expire}]}
    end
  end

  # Speech onset while idle: pre-open the brain's Cartesia TTS websocket now, ahead of the
  # transcript, so the ~100-300ms WSS handshake is done before the endpoint lands. The next
  # :start_brain effect adopts it (BrainStream.begin/3); an unused prewarm is killed by
  # :prewarm_ttl.
  defp handle_turn_start(
         %{policy: %{phase: :listening}, prewarm_brain: nil, voice_activation: va, locked: locked} =
           data
       )
       when not (va and locked) do
    Logger.info("[turn] ◉ turn.start — pre-warming the brain TTS socket")

    {:ok, pid} =
      brain_stream_mod().start(owner: self(), session_id: data.session_id, config: data.config)

    ref = Process.monitor(pid)

    {:keep_state, %{data | prewarm_brain: {pid, ref}},
     [{{:timeout, :prewarm_ttl}, prewarm_ttl_ms(), :expire}]}
  end

  defp handle_turn_start(data) do
    Logger.info("[turn] ◉ turn.start during #{data.policy.phase}")
    {:keep_state, data}
  end

  # ---- policy <-> effects ----
  defp feed(event, data) do
    old_phase = data.policy.phase
    {policy, effects} = Policy.decide(data.policy, event, data.config)
    notify_turn_state(old_phase, policy.phase, data.client)
    {data, actions} = run_effects(effects, %{data | policy: policy})

    # Voice activation: any turn-ending transition back to :listening re-arms the
    # re-lock idle countdown (clean completion, barge-in, watchdog) — so the idle
    # window is measured from when Henry went quiet, not from when the user spoke.
    actions =
      cond do
        # turn-ending transition back to :listening -> (re)arm the idle relock
        data.voice_activation and not data.locked and old_phase != :listening and
            policy.phase == :listening ->
          [relock_action(data) | actions]

        # a live user partial while unlocked is activity -> reset the idle countdown so the
        # session never re-locks mid-utterance (only true silence relocks)
        data.voice_activation and not data.locked and match?({:partial, _}, event) ->
          [relock_action(data) | actions]

        true ->
          actions
      end

    {:keep_state, data, actions}
  end

  # feed(:barge_in, …) + (when an answered turn stashed attrs) the 500ms played-report fallback
  # timer. Takes data that on_barge_in has ALREADY been applied to. pending_interrupt_persist
  # survives feed (:cancel_brain doesn't reset it), so read it off the post-feed data.
  defp barge_in_feed(data) do
    {:keep_state, data, actions} = feed(:barge_in, data)

    if data.pending_interrupt_persist,
      do: {:keep_state, data, [{{:timeout, :interrupt_persist}, 500, :flush} | actions]},
      else: {:keep_state, data, actions}
  end

  # Tell the client when a turn begins / ends so it can gate the mic (half-duplex).
  defp notify_turn_state(:listening, new, client) when new != :listening,
    do: send(client, {:to_client, :speaking})

  defp notify_turn_state(old, :listening, client) when old != :listening,
    do: send(client, {:to_client, :listening})

  defp notify_turn_state(_old, _new, _client), do: :ok

  defp notify_locked(%{client: client, locked: locked}) when is_pid(client),
    do: send(client, {:to_client, {:locked, locked}})

  defp notify_locked(_data), do: :ok

  # W3: one-shot state snapshot so a (re)binding client can reset its UI. "busy" is any
  # non-listening phase — the client only needs the orb-level distinction.
  defp send_state_snapshot(%{client: client} = data) when is_pid(client) do
    phase = if data.policy.phase == :listening, do: "listening", else: "busy"
    send(client, {:to_client, {:state, %{phase: phase, locked: data.locked}}})
  end

  defp send_state_snapshot(_data), do: :ok

  defp run_effects(effects, data), do: Enum.reduce(effects, {data, []}, &run_effect/2)

  defp run_effect({:generate_reflex, t}, {data, acts}) do
    # transcript drives the BRAIN + memory; it folds in any unanswered request carried from a
    # barge-in (so "check my calendar" + barge "also drones?" answers both). The displayed `you:`
    # line + the reflex still use just `t` (the new utterance), so the UI isn't redundant.
    data = %{
      data
      | endpoint_at: System.monotonic_time(:millisecond),
        ttfa: nil,
        ttb: nil,
        transcript: with_pending(data, t),
        pending_request: nil,
        reflex_text: nil
    }

    case {data.agenda_turn, data.speculative_reflex} do
      {{%Item{} = item, mode}, _} ->
        # agenda turn: instant canned lead, no model, and no `you:` transcript line
        {spawn_reflex_lead(lead_for(item, mode), data), acts}

      {nil, {:done, text}} ->
        # eager_end already computed the reflex — speak it instantly, no second Gemini call
        announce_heard(t, data)
        {spawn_reflex_lead(text, %{data | speculative_reflex: nil}), acts}

      {nil, :running} ->
        # eager_end's reflex is still in flight — adopt it (commit); don't start a second call
        announce_heard(t, data)
        {%{data | commit_speculative?: true, speculative_reflex: nil}, acts}

      {nil, nil} ->
        announce_heard(t, data)
        {spawn_reflex_model(t, data), acts}
    end
  end

  defp run_effect({:start_brain, _t}, {data, acts}) do
    send(data.client, {:to_client, :thinking})

    # agenda turns choose their own context isolation (reminders: no recent turns)
    recent? = agenda_recent_context(data.agenda_turn)

    {pid, ref, data} =
      case data.prewarm_brain do
        {pid, ref} when data.agenda_turn == nil ->
          # a prewarmed brain matches this turn's context policy (default recent-context) —
          # adopt it: the Cartesia WS handshake is already done or in flight.
          if Process.alive?(pid) do
            brain_stream_mod().begin(pid, data.transcript, recent?)
            {pid, ref, %{data | prewarm_brain: nil}}
          else
            Process.demonitor(ref, [:flush])
            cold_start_brain(%{data | prewarm_brain: nil}, recent?)
          end

        {pid, ref} ->
          # agenda turns manage their own context — refuse the prewarm
          Process.demonitor(ref, [:flush])
          if Process.alive?(pid), do: Process.exit(pid, :shutdown)
          cold_start_brain(%{data | prewarm_brain: nil}, recent?)

        nil ->
          cold_start_brain(data, recent?)
      end

    {%{
       data
       | brain_pid: pid,
         brain_ref: ref,
         brain_buffer: [],
         audio_until: nil,
         brain_text: nil,
         brain_fallback: false
     }, [{{:timeout, :prewarm_ttl}, :infinity, :cancel} | acts]}
  end

  defp run_effect({:speak_reflex, text}, {data, acts}) do
    send(data.client, {:to_client, {:speak_start, reflex_source(data), text}})
    {spawn_reflex_tts(text, data), acts}
  end

  defp run_effect(:flush_brain, {data, acts}) do
    data =
      data.brain_buffer
      |> Enum.reverse()
      |> Enum.reduce(data, fn pcm, d -> push_audio_chunk(:brain, pcm, d) end)

    {%{data | brain_buffer: []}, acts}
  end

  defp run_effect(:arm_drain, {data, acts}) do
    now = System.monotonic_time(:millisecond)
    delay = max(0, (data.audio_until || now) - now) + data.config.jitter_buffer_ms
    {data, [{{:timeout, :turn_done}, delay, :drained} | acts]}
  end

  defp run_effect(:turn_complete, {data, acts}),
    # cancel_speculative_reflex first: clean completion (unlike barge-in/watchdog) doesn't route
    # through :cancel_brain, so actively kill any lingering speculative task/slot here so a stale
    # head-start can never carry into the next turn.
    do: {data |> cancel_speculative_reflex() |> complete_turn() |> flush_pending_agenda(), acts}

  defp run_effect(:stop_playback, {data, acts}) do
    send(data.client, {:to_client, :stop_playback})
    {data, acts}
  end

  defp run_effect(:cancel_brain, {data, acts}) do
    # A barge/watchdog abort tears down the interrupt window. UNDUCK the client here rather than
    # just clearing the flag: the watchdog path (policy) emits no :stop_playback, so without an
    # explicit unduck a duck armed in the final window would leave the client quiet (the pending
    # timer's own unduck would no-op against the already-cleared flag). Also cancel the window
    # timer so a stale expiry can't unduck a later turn. Clean completion routes through
    # :turn_complete instead (no :cancel_brain) and lets its still-armed timer heal any residual duck.
    data = data |> clear_brain() |> cancel_reflex_tasks() |> unduck()

    {%{
       data
       | brain_buffer: [],
         agenda_turn: nil,
         speculative_reflex: nil,
         commit_speculative?: false,
         interrupt_pending?: false,
         reflex_ms: 0,
         brain_ms: 0
     }, [{{:timeout, :interrupt_pending}, :infinity, :cancel} | acts]}
  end

  defp run_effect(:cancel_reflex, {data, acts}), do: {cancel_reflex_tasks(data), acts}

  defp run_effect({:arm_timer, :watchdog}, {data, acts}),
    do: {data, [{{:timeout, :watchdog}, data.config.turn_max_ms, :watchdog} | acts]}

  # Generation is done; the drain timer now governs playout, so the watchdog (which only
  # guards a stuck *generation*) must not fire mid-playback and abort a long answer.
  defp run_effect(:cancel_watchdog, {data, acts}),
    do: {data, [{{:timeout, :watchdog}, :infinity, :cancel} | acts]}

  defp run_effect(:cancel_timers, {data, acts}) do
    {data,
     [
       {{:timeout, :watchdog}, :infinity, :cancel},
       {{:timeout, :turn_done}, :infinity, :cancel} | acts
     ]}
  end

  defp announce_heard(t, data) do
    Logger.info("[turn] ▶ heard: #{inspect(t)}")
    send(data.client, {:to_client, {:transcript, t}})
  end

  # The audio source/label for the reflex slot: an agenda turn's lead is labeled by item.kind.
  defp reflex_source(%{agenda_turn: {%Item{kind: kind}, _mode}}), do: kind
  defp reflex_source(_), do: :reflex

  defp lead_for(%Item{lead_idle: lead}, :idle), do: lead
  defp lead_for(%Item{lead_interjected: lead}, :interjected), do: lead

  defp agenda_recent_context(nil), do: true
  defp agenda_recent_context({%Item{recent_context: rc}, _mode}), do: rc

  # A briefing is a daily singleton: ignore a second one while one is already queued or in-flight,
  # so the scheduler broadcast and the pull-on-connect injection can't double-speak it.
  defp briefing_duplicate?(%Item{kind: :briefing}, data) do
    Enum.any?(data.pending_agenda, &(&1.kind == :briefing)) or
      match?({%Item{kind: :briefing}, _}, data.agenda_turn)
  end

  defp briefing_duplicate?(_item, _data), do: false

  # ---- reflex tasks ----
  defp spawn_reflex_model(t, data) do
    cfg = data.config

    task =
      Task.Supervisor.async_nolink(App.Conversations.TaskSup, fn ->
        text_model().generate(t, %{}, tier: :reflex, config: cfg, thinking: cfg.reflex_thinking)
      end)

    put_ref(data, task.ref, {:reflex_model, task.pid})
  end

  # Same Gemini reflex call as spawn_reflex_model/2, but tagged :speculative_reflex so its result is
  # HELD (not spoken) — see handle_reflex_result(:speculative_reflex, …).
  defp spawn_speculative_reflex(t, data) do
    cfg = data.config

    task =
      Task.Supervisor.async_nolink(App.Conversations.TaskSup, fn ->
        text_model().generate(t, %{}, tier: :reflex, config: cfg, thinking: cfg.reflex_thinking)
      end)

    put_ref(data, task.ref, {:speculative_reflex, task.pid})
  end

  defp spawn_reflex_tts(text, data) do
    cfg = data.config

    task =
      Task.Supervisor.async_nolink(App.Conversations.TaskSup, fn ->
        tts().synthesize(text, tts_opts(cfg))
      end)

    put_ref(data, task.ref, {:reflex_tts, task.pid})
  end

  # An agenda item becomes a self-initiated turn: instant canned lead (reflex slot) then the
  # brain fulfills item.prompt with tools (brain slot). Ack (e.g. reminder acknowledge) runs
  # off the FSM. Returns a gen_statem result (feed/2).
  defp start_agenda_turn(item, mode, data) do
    Logger.info("[agenda] fulfilling #{item.kind} (#{mode})")
    run_ack_async(item)
    data = cancel_speculative_reflex(data)
    # set the marker BEFORE feed/2 — generate_reflex runs inside this feed and branches on it
    data = %{data | agenda_turn: {item, mode}}
    feed({:endpoint, item.prompt}, data)
  end

  defp run_ack_async(%Item{ack: {m, f, a}}) do
    Task.Supervisor.start_child(App.Conversations.TaskSup, fn -> apply(m, f, a) end)
    :ok
  end

  defp run_ack_async(_item), do: :ok

  # Reflex slot for an agenda turn: return the canned lead instantly (no model call). We route
  # it through a task + the :reflex_model result path (rather than feeding :reflex_ready directly)
  # so it shares the exact put_ref/demonitor/cancel_reflex_tasks machinery — barge-in/watchdog
  # cancel it uniformly with a normal reflex, no special-casing.
  defp spawn_reflex_lead(lead, data) do
    task = Task.Supervisor.async_nolink(App.Conversations.TaskSup, fn -> {:ok, lead} end)
    put_ref(data, task.ref, {:reflex_model, task.pid})
  end

  defp flush_pending_agenda(%{pending_agenda: []} = data), do: data

  # On clean completion, hand each queued item back to ourselves as its own turn. We can't
  # start a turn inline here (we're mid-feed/:turn_complete); a fresh {:deliver_agenda, item}
  # message starts it from a clean state. Sequential by construction.
  defp flush_pending_agenda(%{pending_agenda: items} = data) do
    Enum.each(Enum.reverse(items), &send(self(), {:deliver_agenda, &1}))
    %{data | pending_agenda: []}
  end

  defp tts_opts(cfg) do
    [
      voice_id: cfg.voice_id,
      tts_speed: cfg.tts_speed,
      tts_volume: cfg.tts_volume,
      tts_emotion: cfg.tts_emotion,
      sample_rate: cfg.tts_sample_rate,
      model: cfg.tts_model,
      version: cfg.cartesia_version
    ]
  end

  defp cancel_reflex_tasks(data) do
    Enum.each(data.refs, fn {ref, {_kind, pid}} ->
      Process.demonitor(ref, [:flush])
      Task.Supervisor.terminate_child(App.Conversations.TaskSup, pid)
    end)

    %{data | refs: %{}}
  end

  # Cancel ONLY the speculative reflex task (leave any real reflex/TTS refs alone) and clear the slot.
  defp cancel_speculative_reflex(data) do
    data =
      Enum.reduce(data.refs, data, fn
        {ref, {:speculative_reflex, pid}}, acc ->
          Process.demonitor(ref, [:flush])
          Task.Supervisor.terminate_child(App.Conversations.TaskSup, pid)
          %{acc | refs: Map.delete(acc.refs, ref)}

        _other, acc ->
          acc
      end)

    %{data | speculative_reflex: nil, commit_speculative?: false}
  end

  defp put_ref(data, ref, value), do: %{data | refs: Map.put(data.refs, ref, value)}

  # ---- the streaming brain ----
  defp clear_brain(%{brain_ref: nil} = data), do: data

  defp clear_brain(data) do
    Process.demonitor(data.brain_ref, [:flush])

    if data.brain_pid && Process.alive?(data.brain_pid),
      do: Process.exit(data.brain_pid, :shutdown)

    %{data | brain_pid: nil, brain_ref: nil}
  end

  # ---- audio out + metrics ----
  defp push_audio_chunk(source, pcm, data) do
    now = System.monotonic_time(:millisecond)
    dur = trunc(byte_size(pcm) / (2 * data.config.tts_sample_rate) * 1000)

    data =
      case source do
        :brain -> %{data | brain_ms: data.brain_ms + dur}
        _ -> %{data | reflex_ms: data.reflex_ms + dur}
      end

    data = %{data | audio_until: max(data.audio_until || now, now) + dur}
    data = record_metrics(source, data)
    send(data.client, {:to_client, {:audio, source, pcm}})
    data
  end

  defp record_metrics(_source, %{endpoint_at: nil} = data), do: data

  defp record_metrics(source, data) do
    elapsed = System.monotonic_time(:millisecond) - data.endpoint_at
    ttfa = if source == :reflex and is_nil(data.ttfa), do: elapsed, else: data.ttfa
    ttb = if source == :brain and is_nil(data.ttb), do: elapsed, else: data.ttb

    # Only emit when something actually changed — the brain pushes many chunks but
    # TTB is set just once.
    if {ttfa, ttb} == {data.ttfa, data.ttb} do
      data
    else
      data = %{data | ttfa: ttfa, ttb: ttb}

      measurements =
        %{ttfa: ttfa, ttb: ttb} |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()

      :telemetry.execute([:app, :turn, :audio], measurements, %{source: source})
      Logger.info("[turn] metrics: ttfa=#{inspect(ttfa)}ms ttb=#{inspect(ttb)}ms (#{source})")
      send(data.client, {:to_client, {:metrics, ttfa, ttb}})
      data
    end
  end

  # ---- memory: persist the turn, THEN (single-flight) recompute the summary ----
  # Agenda turns aren't user conversation. persist_as: nil -> don't store (reminders today);
  # persist_as: "…" -> store the exchange under that user_text (e.g. "(morning briefing)") so
  # follow-up questions have history — persist only, no memory-updater run.
  defp complete_turn(%{agenda_turn: {%Item{persist_as: nil}, _mode}} = data),
    do: reset_turn_fields(%{data | agenda_turn: nil})

  defp complete_turn(%{agenda_turn: {%Item{persist_as: label}, _mode}, session_id: sid} = data)
       when is_binary(label) do
    case sid && App.Users.id_from_session(sid) do
      nil ->
        reset_turn_fields(%{data | agenda_turn: nil})

      user_id ->
        attrs = %{
          user_id: user_id,
          user_text: label,
          reflex_text: data.reflex_text,
          brain_text: data.brain_text,
          ttfa_ms: data.ttfa,
          ttb_ms: data.ttb
        }

        Task.Supervisor.start_child(App.Conversations.TaskSup, fn -> persist_turn(attrs) end)
        reset_turn_fields(%{data | agenda_turn: nil})
    end
  end

  defp complete_turn(%{session_id: nil} = data), do: reset_turn_fields(data)

  defp complete_turn(%{session_id: sid} = data) do
    case App.Users.id_from_session(sid) do
      nil ->
        reset_turn_fields(data)

      user_id ->
        attrs = %{
          user_id: user_id,
          user_text: data.transcript,
          reflex_text: data.reflex_text,
          brain_text: data.brain_text,
          ttfa_ms: data.ttfa,
          ttb_ms: data.ttb
        }

        # Persist first, then the updater (so the rolling summary actually sees this turn —
        # they used to race). Single-flight the updater: while one runs, later turns only persist.
        if is_nil(data.updater_ref) do
          task =
            Task.Supervisor.async_nolink(App.Conversations.TaskSup, fn ->
              persist_turn(attrs)
              App.Memory.Updater.run(sid)
            end)

          reset_turn_fields(%{data | updater_ref: task.ref})
        else
          Task.Supervisor.start_child(App.Conversations.TaskSup, fn -> persist_turn(attrs) end)
          reset_turn_fields(data)
        end
    end
  end

  defp persist_turn(attrs) do
    case App.Memory.persist_turn(attrs) do
      {:ok, _} -> :ok
      {:error, reason} -> Logger.warning("[memory] persist failed: #{inspect(reason)}")
    end
  end

  # What to do with the turn the user just interrupted:
  #   * the brain ALREADY answered (brain_text set, e.g. barged during draining) → a complete
  #     exchange the user heard, so PERSIST it (else the offer is discarded and the brain forgets
  #     it — proposes two events, you barge "yes both", it loops back to "pick one").
  #   * the brain had NOT answered yet → the request is UNFULFILLED, so carry it forward: stash the
  #     transcript so the next turn folds it in and the brain answers both ("check my calendar" +
  #     barge "also drones?" → both). It's then persisted as part of that next turn, not separately.
  defp on_barge_in(%{brain_text: bt} = data) when is_binary(bt), do: persist_interrupted(data)

  defp on_barge_in(%{agenda_turn: nil, transcript: t} = data)
       when is_binary(t) and t != "",
       do: %{data | pending_request: t}

  defp on_barge_in(data), do: data

  # Fold any carried-forward unanswered request in front of the new utterance (for the brain only).
  defp with_pending(%{pending_request: req}, t) when is_binary(req) and req != "",
    do: req <> " " <> t

  defp with_pending(_data, t), do: t

  # The user barged after the brain answered. Persisting immediately would record the FULL
  # answer even if they heard three words — so stash the attrs, ask time for the client's
  # `played` report (it arrives right after stop_playback), and persist truncated. A missing
  # report falls back to the full text after 500ms (never worse than today).
  defp persist_interrupted(%{session_id: sid, agenda_turn: nil, transcript: t} = data)
       when is_binary(sid) and is_binary(t) and t != "" do
    case App.Users.id_from_session(sid) do
      nil ->
        data

      user_id ->
        data = flush_interrupt_persist(data, :full)

        attrs = %{
          user_id: user_id,
          user_text: t,
          reflex_text: data.reflex_text,
          brain_text: data.brain_text,
          ttfa_ms: data.ttfa,
          ttb_ms: data.ttb
        }

        %{data | pending_interrupt_persist: {attrs, data.reflex_ms, data.brain_ms}}
    end
  end

  defp persist_interrupted(data), do: data

  # Persist the stashed interrupted turn. :full keeps the whole answer; {:played, ms} truncates
  # brain_text to the heard fraction.
  defp flush_interrupt_persist(%{pending_interrupt_persist: nil} = data, _how), do: data

  defp flush_interrupt_persist(
         %{pending_interrupt_persist: {attrs, reflex_ms, brain_ms}} = data,
         how
       ) do
    attrs =
      case how do
        {:played, played_ms} when brain_ms > 0 and is_binary(attrs.brain_text) ->
          heard = max(0, played_ms - reflex_ms)
          %{attrs | brain_text: truncate_heard(attrs.brain_text, heard / brain_ms)}

        _ ->
          attrs
      end

    Task.Supervisor.start_child(App.Conversations.TaskSup, fn -> persist_turn(attrs) end)
    %{data | pending_interrupt_persist: nil}
  end

  @doc false
  # Cut `text` to `fraction` of its characters, snapped back to the last word boundary, with an
  # explicit marker so the brain (which sees history) knows the user never heard the rest.
  def truncate_heard(text, fraction) when fraction >= 0.95, do: text

  def truncate_heard(text, fraction) do
    keep = trunc(String.length(text) * max(fraction, 0.0))

    prefix =
      text
      |> String.slice(0, keep)
      |> String.replace(~r/\s+\S*\z/u, "")

    case prefix do
      "" -> "—[interrupted]"
      p -> p <> " —[interrupted]"
    end
  end

  # Clear per-turn accumulators (metrics included, so stale values can't leak into the
  # next turn or re-trigger the brain fallback).
  # NOTE: ptt_mode/holding/expecting_finalize are intentionally NOT reset here — they persist
  # across turns and are cleared only on press/release/set_ptt. pending_interrupt_persist is
  # ALSO intentionally not reset here — it outlives the turn until flushed.
  defp reset_turn_fields(data),
    do: %{
      data
      | brain_buffer: [],
        audio_until: nil,
        brain_fallback: false,
        ttfa: nil,
        ttb: nil,
        speculative_reflex: nil,
        commit_speculative?: false,
        interrupt_pending?: false,
        pending_request: nil,
        reflex_ms: 0,
        brain_ms: 0
    }

  # Clean up the unlinked brain — and any pre-warmed-but-unadopted brain — on shutdown (the
  # linked STT dies with us via its link).
  @impl true
  def terminate(_reason, _state, data) do
    kill_brain(Map.get(data, :brain_pid))
    kill_brain(prewarm_pid(data))
    :ok
  end

  defp prewarm_pid(%{prewarm_brain: {pid, _ref}}), do: pid
  defp prewarm_pid(_data), do: nil

  defp kill_brain(pid) when is_pid(pid) do
    if Process.alive?(pid), do: Process.exit(pid, :shutdown)
  end

  defp kill_brain(_pid), do: :ok

  defp relock_ms(%{relock_ms: ms}) when is_integer(ms), do: ms
  defp relock_ms(_data), do: Application.get_env(:app, :relock_ms, 15_000)

  defp linger_ms, do: Application.get_env(:app, :client_linger_ms, 120_000)

  defp prewarm_ttl_ms, do: Application.get_env(:app, :prewarm_ttl_ms, 15_000)

  defp text_model, do: Application.fetch_env!(:app, :text_model)
  defp tts, do: Application.fetch_env!(:app, :tts)
  defp brain_stream_mod, do: Application.fetch_env!(:app, :brain_stream)
end
