defmodule App.Conversations.PolicyTest do
  use ExUnit.Case, async: true
  alias App.Conversations.Policy
  alias App.Config

  @config %Config{}

  defp decide(state, event), do: Policy.decide(state, event, @config)

  test "endpoint starts reflex + brain stream and arms the watchdog" do
    {state, effects} = decide(Policy.initial_state(), {:endpoint, "hi"})
    assert state.phase == :awaiting_reflex
    assert state.transcript == "hi"
    assert effects == [{:generate_reflex, "hi"}, {:start_brain, "hi"}, {:arm_timer, :watchdog}]
  end

  test "endpoint mid-turn is ignored" do
    state = %{Policy.initial_state() | phase: :streaming}
    assert {^state, []} = decide(state, {:endpoint, "again"})
  end

  test "reflex_ready -> speak reflex" do
    state = %{Policy.initial_state() | phase: :awaiting_reflex}

    assert {%{phase: :speaking_reflex}, [{:speak_reflex, "huh"}]} =
             decide(state, {:reflex_ready, "huh"})
  end

  test "reflex_sent opens the gate and flushes buffered brain audio" do
    state = %{Policy.initial_state() | phase: :speaking_reflex}
    {state, effects} = decide(state, :reflex_sent)
    assert state.phase == :streaming
    assert state.reflex_sent
    assert effects == [:flush_brain]
  end

  test "reflex_sent also arms the drain (+ cancels watchdog) if the brain already finished" do
    state = %{Policy.initial_state() | phase: :speaking_reflex, brain_done: true}
    {state, effects} = decide(state, :reflex_sent)
    assert state.phase == :draining
    assert effects == [:flush_brain, :cancel_watchdog, :arm_drain]
  end

  test "brain_done while streaming -> draining, cancels watchdog + arms drain" do
    state = %{Policy.initial_state() | phase: :streaming, reflex_sent: true}

    assert {%{phase: :draining, brain_done: true}, [:cancel_watchdog, :arm_drain]} =
             decide(state, :brain_done)
  end

  test "brain_done before the reflex spoke is remembered, not yet drained" do
    state = %{Policy.initial_state() | phase: :speaking_reflex}
    assert {%{brain_done: true, phase: :speaking_reflex}, []} = decide(state, :brain_done)
  end

  test "drained completes the turn and resets" do
    state = %{Policy.initial_state() | phase: :draining}
    assert {%{phase: :listening}, [:turn_complete, :cancel_timers]} = decide(state, :drained)
  end

  test "barge-in aborts everything (except while listening)" do
    state = %{Policy.initial_state() | phase: :streaming}

    assert {%{phase: :listening}, [:stop_playback, :cancel_brain, :cancel_timers]} =
             decide(state, :barge_in)

    assert {%{phase: :listening}, []} = decide(Policy.initial_state(), :barge_in)
  end

  test "watchdog aborts a stuck turn" do
    state = %{Policy.initial_state() | phase: :streaming}
    assert {%{phase: :listening}, [:cancel_brain, :cancel_timers]} = decide(state, :watchdog)
  end
end
