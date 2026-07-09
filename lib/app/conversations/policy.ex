defmodule App.Conversations.Policy do
  @moduledoc """
  Pure streaming-turn reducer. `decide(state, event, config) -> {state, effects}`.

  A turn: the fast **reflex** (batch) leads instantly while the **brain** streams audio
  (Gemini SSE → Cartesia WS → chunks). Brain audio is held until the reflex audio has
  been sent, then flushed + streamed; the turn completes once the audio timeline drains.
  No I/O or time access here — the `Conversation` gen_statem owns the pcm buffer, the
  audio timeline, timers, and all effects.

  Effects: `{:generate_reflex, t}`, `{:start_brain, t}`, `{:speak_reflex, text}`,
  `:flush_brain`, `:arm_drain`, `:turn_complete`, `:stop_playback`, `:cancel_brain`,
  `{:arm_timer, :watchdog}`, `:cancel_timers`.
  """
  alias App.Config

  @type phase :: :listening | :awaiting_reflex | :speaking_reflex | :streaming | :draining

  @type state :: %{
          phase: phase(),
          transcript: String.t(),
          reflex_sent: boolean(),
          brain_done: boolean()
        }

  @spec initial_state() :: state()
  def initial_state,
    do: %{phase: :listening, transcript: "", reflex_sent: false, brain_done: false}

  @spec decide(state(), term(), Config.t()) :: {state(), [term()]}
  def decide(state, event, config)

  # --- endpoint: start the turn (reflex + brain stream in parallel) ---
  def decide(%{phase: :listening} = s, {:endpoint, t}, _c) do
    {%{s | phase: :awaiting_reflex, transcript: t, reflex_sent: false, brain_done: false},
     [{:generate_reflex, t}, {:start_brain, t}, {:arm_timer, :watchdog}]}
  end

  def decide(s, {:endpoint, _t}, _c), do: {s, []}

  # --- reflex text ready: speak it ---
  def decide(%{phase: :awaiting_reflex} = s, {:reflex_ready, text}, _c) do
    {%{s | phase: :speaking_reflex}, [{:speak_reflex, text}]}
  end

  def decide(s, {:reflex_ready, _text}, _c), do: {s, []}

  # --- reflex audio has been pushed: open the gate, flush buffered brain audio ---
  # If the brain ALREADY finished generating (raced ahead of the reflex TTS), go straight to
  # :draining — else the later :drained event hits the no-op clause and the turn never completes
  # (and the watchdog was just cancelled, so there's no backstop). Otherwise stream as usual.
  def decide(%{phase: :speaking_reflex} = s, :reflex_sent, _c) do
    cond do
      s.brain_done ->
        {%{s | phase: :draining, reflex_sent: true}, [:flush_brain, :cancel_watchdog, :arm_drain]}

      true ->
        {%{s | phase: :streaming, reflex_sent: true}, [:flush_brain]}
    end
  end

  def decide(s, :reflex_sent, _c), do: {s, []}

  # --- brain stream finished generating: cancel the watchdog (it only guards a stuck
  # *generation*) so it can't abort a long answer mid-playback; the drain timer governs ---
  def decide(%{phase: :streaming} = s, :brain_done, _c) do
    {%{s | phase: :draining, brain_done: true}, [:cancel_watchdog, :arm_drain]}
  end

  # finished before the reflex even spoke -> remember; `:reflex_sent` will arm the drain
  def decide(%{phase: p} = s, :brain_done, _c) when p in [:awaiting_reflex, :speaking_reflex] do
    {%{s | brain_done: true}, []}
  end

  def decide(s, :brain_done, _c), do: {s, []}

  # --- the audio timeline drained: complete the turn ---
  def decide(%{phase: :draining}, :drained, _c) do
    {initial_state(), [:turn_complete, :cancel_timers]}
  end

  def decide(s, :drained, _c), do: {s, []}

  # --- barge-in: abort everything ---
  def decide(%{phase: :listening} = s, :barge_in, _c), do: {s, []}

  def decide(_s, :barge_in, _c) do
    {initial_state(), [:stop_playback, :cancel_brain, :cancel_timers]}
  end

  # --- watchdog: backstop abort of a stuck turn ---
  def decide(%{phase: :listening} = s, :watchdog, _c), do: {s, []}
  def decide(_s, :watchdog, _c), do: {initial_state(), [:cancel_brain, :cancel_timers]}

  # --- partial transcript (only meaningful while listening) ---
  def decide(%{phase: :listening} = s, {:partial, t}, _c), do: {%{s | transcript: t}, []}
  def decide(s, {:partial, _t}, _c), do: {s, []}

  # --- unknown events are no-ops ---
  def decide(s, _event, _c), do: {s, []}
end
