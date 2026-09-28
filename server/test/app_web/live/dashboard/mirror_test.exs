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
end
