defmodule AppWeb.Dashboard.MirrorTest do
  use ExUnit.Case, async: true

  alias AppWeb.Dashboard.Mirror

  defp run(events), do: Enum.reduce(events, {Mirror.new(), []}, &step/2)

  defp step(event, {state, rows}) do
    {state, new_rows} = Mirror.apply_event(state, event)
    {state, rows ++ new_rows}
  end

  test "a partial is the caption; the transcript clears it and becomes a you row" do
    {state, rows} = run([{:partial, "what's the"}])
    assert state.caption == "what's the"
    assert rows == []

    {state, [row]} = Mirror.apply_event(state, {:transcript, "what's the weather"})
    assert state.caption == nil
    assert %{kind: :you, text: "what's the weather"} = row
  end

  test "brain deltas grow ONE row in place, and the final speak_start replaces its text" do
    {_state, rows} =
      run([
        {:transcript, "q"},
        {:brain_delta, "The "},
        {:brain_delta, "answ"},
        {:speak_start, :brain, "The answer."}
      ])

    brain = Enum.filter(rows, &(&1.kind == :brain))
    assert brain |> Enum.map(& &1.id) |> Enum.uniq() |> length() == 1
    assert Enum.map(brain, & &1.text) == ["The ", "The answ", "The answer."]
  end

  test "a brain answer with no deltas is one row" do
    {_state, rows} = run([{:transcript, "q"}, {:speak_start, :brain, "Sure."}])
    assert [%{kind: :you}, %{kind: :brain, text: "Sure."}] = rows
  end

  test "a delta after listening starts a new row (an agenda turn has no transcript)" do
    {_state, rows} =
      run([
        {:brain_delta, "first"},
        {:phase, :listening},
        {:speak_start, :reminder, "Heads up —"},
        {:brain_delta, "second"}
      ])

    [first, reminder, second] = rows
    assert first.kind == :brain and second.kind == :brain
    assert first.id != second.id
    assert second.text == "second"
    assert reminder.kind == :reminder
  end

  test "reflex, tool and metrics rows; metrics fills in place" do
    {_state, rows} =
      run([
        {:transcript, "q"},
        {:speak_start, :reflex, "Hm."},
        {:tool_call, "get_weather"},
        {:metrics, 640, nil},
        {:metrics, 640, 3_410}
      ])

    assert Enum.find(rows, &(&1.kind == :reflex)).text == "Hm."
    assert Enum.find(rows, &(&1.kind == :tool)).text == "get_weather"
    metrics = Enum.filter(rows, &(&1.kind == :metrics))
    assert Enum.map(metrics, & &1.text) == ["audio 0.6s", "audio 0.6s · brain 3.4s"]
    assert metrics |> Enum.map(& &1.id) |> Enum.uniq() |> length() == 1
  end

  test "an agenda turn's metrics get their own row, not the previous turn's (finding #1)" do
    {state, rows} =
      run([
        {:transcript, "what's the weather"},
        {:metrics, 640, 3_000}
      ])

    [_you, first_metrics] = rows
    assert first_metrics.kind == :metrics
    assert first_metrics.text == "audio 0.6s · brain 3.0s"

    # Turn ends, an agenda turn (reminder) starts with no transcript of its own.
    {state, agenda_rows} =
      [
        {:phase, :listening},
        {:speak_start, :reminder, "Heads up —"},
        {:metrics, nil, 1_200}
      ]
      |> Enum.reduce({state, []}, &step/2)

    reminder_metrics = Enum.find(agenda_rows, &(&1.kind == :metrics))
    assert reminder_metrics.text == "brain 1.2s"
    assert reminder_metrics.id != first_metrics.id
    assert state.metrics.id == reminder_metrics.id
    # The first turn's row, as last emitted, is untouched.
    assert first_metrics.text == "audio 0.6s · brain 3.0s"
  end

  test "status follows phase, lock, bound device and session start" do
    {state, []} =
      run([
        :session_started,
        {:phase, :streaming},
        {:locked, true},
        {:bound_device, "abcdef0123456789"}
      ])

    assert state.status == %{
             session: :live,
             phase: :streaming,
             locked: true,
             bound_device: "abcdef0123456789"
           }
  end

  test "put_snapshot seeds the strip; nil means no session" do
    state =
      Mirror.put_snapshot(Mirror.new(), %{phase: :listening, locked: false, bound_device: "d"})

    assert state.status == %{session: :live, phase: :listening, locked: false, bound_device: "d"}

    state = Mirror.put_snapshot(state, nil)
    assert state.status == %{session: :none, phase: nil, locked: nil, bound_device: nil}
  end

  test "unknown events are ignored" do
    assert {%Mirror{}, []} = Mirror.apply_event(Mirror.new(), {:reminder_ack_offer, 3})
  end

  test "history: oldest first, one you + one brain row per turn, empty answers skipped" do
    turns = [
      %{id: 1, user_text: "hi", brain_text: "hello"},
      %{id: 2, user_text: "and?", brain_text: nil}
    ]

    assert [
             %{id: "h-1-you", kind: :you, text: "hi"},
             %{id: "h-1-brain", kind: :brain, text: "hello"},
             %{id: "h-2-you", kind: :you, text: "and?"}
           ] = Mirror.history_rows(turns)
  end

  test "the caption clears on {:phase, :listening} (finding #2a)" do
    {state, []} = Mirror.apply_event(Mirror.new(), {:partial, "half a sent"})
    assert state.caption == "half a sent"

    {state, []} = Mirror.apply_event(state, {:phase, :listening})
    assert state.caption == nil
  end

  test "the caption clears on {:locked, _} (finding #2a)" do
    {state, []} = Mirror.apply_event(Mirror.new(), {:partial, "half a sent"})
    assert state.caption == "half a sent"

    {state, []} = Mirror.apply_event(state, {:locked, true})
    assert state.caption == nil
    assert state.status.locked == true
  end

  test "a Voice Lock drop clears the caption and adds a gate row (finding #2b)" do
    {state, []} = Mirror.apply_event(Mirror.new(), {:partial, "lyrics from a song"})
    assert state.caption == "lyrics from a song"

    {state, [row]} = Mirror.apply_event(state, {:voice_gate, :drop})
    assert state.caption == nil
    assert %{kind: :gate, text: "filtered by Voice Lock"} = row
  end

  test "no session clears live turn state (caption, brain, metrics)" do
    # Simulate session 1 ending mid-answer.
    state =
      Mirror.new()
      |> then(fn s -> elem(Mirror.apply_event(s, {:partial, "half"}), 0) end)
      |> then(fn s -> elem(Mirror.apply_event(s, {:brain_delta, "old"}), 0) end)

    assert state.caption == "half"
    assert state.live_brain != nil
    old_id = state.live_brain.id

    # Session ends (snapshot nil), then session 2 starts.
    state = Mirror.put_snapshot(state, nil)
    assert state.caption == nil
    assert state.live_brain == nil
    assert state.metrics == nil

    # Session 2's first turn is an agenda turn (no transcript).
    # Brain deltas must open a fresh row, not append to the previous session's.
    {_state, [row]} = Mirror.apply_event(state, {:brain_delta, "new"})

    assert row.text == "new"
    # Verify it's a different row than the old one (ids must be unique across sessions).
    assert row.id != old_id
  end
end
