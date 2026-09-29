defmodule AppWeb.Dashboard.Mirror do
  @moduledoc """
  Pure reducer from a conversation's mirrored events (`{:mirror, event}` on
  "conversation:<session_id>", see `App.Conversations.Conversation`) to what the dashboard
  draws: thread rows, the live partial caption, and the status strip.

  `apply_event/2` returns the new state plus the rows to `stream_insert/3`. A row is returned
  again, with the same id, whenever its text changes: that is how the brain's answer grows in
  place and how the metrics line fills in its second number.
  """

  defstruct seq: 0,
            live_brain: nil,
            metrics: nil,
            caption: nil,
            status: %{session: :none, phase: nil, locked: nil, bound_device: nil}

  @type row :: %{id: String.t(), kind: atom(), text: String.t()}
  @type t :: %__MODULE__{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Saved turns, oldest first (as `App.Memory.recent_turns/2` returns them), as rows."
  @spec history_rows([map()]) :: [row()]
  def history_rows(turns) do
    Enum.flat_map(turns, fn t ->
      [
        %{id: "h-#{t.id}-you", kind: :you, text: t.user_text || ""},
        %{id: "h-#{t.id}-brain", kind: :brain, text: t.brain_text || ""}
      ]
      # A turn persisted mid-barge has no answer; an empty bubble says nothing.
      |> Enum.reject(&(&1.text == ""))
    end)
  end

  @spec apply_event(t(), term()) :: {t(), [row()]}
  def apply_event(state, {:partial, text}), do: {%{state | caption: text}, []}

  def apply_event(state, {:transcript, text}),
    do: new_row(%{state | caption: nil, live_brain: nil, metrics: nil}, :you, text)

  # The final answer: the server sends it whole after (or instead of) the deltas.
  def apply_event(%{live_brain: %{} = row} = state, {:speak_start, :brain, text}) do
    row = %{row | text: text}
    {%{state | live_brain: nil}, [row]}
  end

  def apply_event(state, {:speak_start, source, text}), do: new_row(state, source, text)

  def apply_event(%{live_brain: %{} = row} = state, {:brain_delta, delta}) do
    row = %{row | text: row.text <> delta}
    {%{state | live_brain: row}, [row]}
  end

  def apply_event(state, {:brain_delta, delta}) do
    {state, [row]} = new_row(state, :brain, delta)
    {%{state | live_brain: row}, [row]}
  end

  def apply_event(state, {:tool_call, name}), do: new_row(state, :tool, to_string(name))

  # Voice Lock dropped this utterance before it became a transcript — the only signal that a
  # heard-but-rejected utterance ever produces (spec 2026-09-26-web-admin-dashboard-design,
  # controller ruling on the final review). The ack-echo drop is different: it sends NO event
  # at all, so a caption it leaves behind is only cleared later, by the next {:phase,
  # :listening} or {:locked, _} — acceptable, per the same ruling.
  def apply_event(state, {:voice_gate, :drop}),
    do: new_row(%{state | caption: nil}, :gate, "filtered by Voice Lock")

  def apply_event(state, {:metrics, ttfa, ttb}) do
    text = metrics_text(ttfa, ttb)

    case state.metrics do
      %{} = row ->
        row = %{row | text: text}
        {%{state | metrics: row}, [row]}

      nil ->
        {state, [row]} = new_row(state, :metrics, text)
        {%{state | metrics: row}, [row]}
    end
  end

  # Back at :listening the turn is over: the next delta (an agenda turn has no transcript to
  # reset on) must open a fresh answer row rather than append to this one, the next metrics
  # event must open a fresh row rather than overwrite the just-finished turn's, and any
  # "hearing" caption left behind by an utterance that never reached a transcript (a sleep
  # command, a Voice Lock gate drop with no follow-up, an ack echo) must not strand there.
  def apply_event(state, {:phase, phase}) do
    state = put_status(state, session: :live, phase: phase)

    state =
      if phase == :listening,
        do: %{state | live_brain: nil, metrics: nil, caption: nil},
        else: state

    {state, []}
  end

  # Same caption-stranding concern as {:phase, :listening} above: a sleep command ("Henry, go
  # to sleep") endpoints straight to `{:locked, true}` with no transcript in between.
  def apply_event(state, {:locked, locked}),
    do: {%{put_status(state, locked: locked) | caption: nil}, []}

  def apply_event(state, {:bound_device, id}), do: {put_status(state, bound_device: id), []}
  def apply_event(state, :session_started), do: {put_status(state, session: :live), []}
  def apply_event(state, _event), do: {state, []}

  @doc "Adopt a `Conversation.snapshot/1` into the strip; nil means no session is running."
  @spec put_snapshot(t(), map() | nil) :: t()
  def put_snapshot(state, nil) do
    # No session means no turn in flight: clear live turn state so the next turn opens fresh.
    state
    |> then(&%{&1 | caption: nil, live_brain: nil, metrics: nil})
    |> put_status(session: :none, phase: nil, locked: nil, bound_device: nil)
  end

  def put_snapshot(state, %{phase: phase, locked: locked, bound_device: device}),
    do: put_status(state, session: :live, phase: phase, locked: locked, bound_device: device)

  defp new_row(state, kind, text) do
    seq = state.seq + 1
    {%{state | seq: seq}, [%{id: "live-#{seq}", kind: kind, text: text}]}
  end

  defp put_status(state, kv), do: %{state | status: Map.merge(state.status, Map.new(kv))}

  # Same words as the app's latency line (native thread_model.dart).
  defp metrics_text(ttfa, ttb) do
    [ttfa && "audio #{secs(ttfa)}", ttb && "brain #{secs(ttb)}"]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp secs(ms), do: :erlang.float_to_binary(ms / 1000, decimals: 1) <> "s"
end
