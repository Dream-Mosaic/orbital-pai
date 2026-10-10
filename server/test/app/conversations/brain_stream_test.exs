defmodule App.Conversations.BrainStreamTest do
  use ExUnit.Case, async: true
  alias App.Conversations.BrainStream
  alias App.Config

  test "tts_message wires generation_config from config and drops the deprecated top-level speed" do
    cfg = %Config{
      voice_id: "v1",
      tts_model: "sonic-2",
      tts_sample_rate: 44_100,
      tts_speed: 1.3,
      tts_volume: 0.9,
      tts_emotion: nil
    }

    msg = BrainStream.tts_message(cfg, "hi", true, "brain")

    refute Map.has_key?(msg, :speed)
    assert msg.transcript == "hi"
    assert msg.continue == true
    assert msg.context_id == "brain"
    assert msg.voice == %{mode: "id", id: "v1"}
    assert msg.generation_config == %{speed: 1.3, volume: 0.9}
    assert msg.output_format.sample_rate == 44_100
  end

  test "tts_message includes max_buffer_delay_ms only when configured" do
    base = BrainStream.tts_message(%Config{}, "hi", true, "c-0")
    refute Map.has_key?(base, :max_buffer_delay_ms)

    tuned = BrainStream.tts_message(%Config{tts_max_buffer_delay_ms: 1200}, "hi", true, "c-0")
    assert tuned.max_buffer_delay_ms == 1200
  end

  test "a gemini delta emits {:brain_text, text} to the owner and still accumulates" do
    state = %{ready: false, pending: [], text: "", owner: self()}
    {:noreply, new_state} = BrainStream.handle_info({:gemini_delta, "hello "}, state)

    assert_receive {:brain_text, "hello "}
    assert new_state.text == "hello "
    assert new_state.pending == ["hello "]
  end

  test "a gemini bridge does NOT emit brain_text (filler stays out of captions)" do
    state = %{ready: false, pending: [], text: "answer", owner: self()}
    {:noreply, new_state} = BrainStream.handle_info({:gemini_bridge, "checking, one sec"}, state)

    refute_receive {:brain_text, _}, 100
    assert new_state.text == "answer"
  end

  test "a gemini tool call is relayed to the owner as brain_tool_call" do
    state = %{ready: false, pending: [], text: "", owner: self()}
    {:noreply, _new_state} = BrainStream.handle_info({:gemini_tool_call, "x"}, state)

    assert_receive {:brain_tool_call, "x"}
  end

  test "a gemini tool result is relayed to the owner, ready or not (it never touches TTS)" do
    for ready <- [false, true] do
      state = %{ready: ready, pending: [], text: "", owner: self()}
      msg = {:gemini_tool_result, "get_weather", %{"location" => "home"}, %{location: "X"}}
      {:noreply, ^state} = BrainStream.handle_info(msg, state)

      assert_receive {:brain_tool_result, "get_weather", %{"location" => "home"},
                      %{location: "X"}}
    end
  end

  # ---- context rotation: a Cartesia context expires 1s after its last audio (docs). A long tool
  # gap (silent bridge→answer) expires the context before the answer; we rotate to a fresh one
  # instead of ending the turn empty. ----

  defp done_frame, do: {:text, Jason.encode!(%{"type" => "done"})}

  test "a cartesia 'done' while the brain is still working rotates the context, NOT ends the turn" do
    state = %{context_base: "brain", context_seq: 0, gemini_done: false, text: "", owner: self()}
    new_state = BrainStream.handle_frame(done_frame(), state)

    assert new_state.context_seq == 1, "the expired context should be rotated"
    refute_received {:brain_done, _}, "a mid-turn expiry must not end the turn"
  end

  test "a cartesia 'done' after the brain is done ends the turn with the answer text" do
    state = %{
      context_base: "brain",
      context_seq: 1,
      gemini_done: true,
      text: "the answer",
      owner: self()
    }

    new_state = BrainStream.handle_frame(done_frame(), state)

    assert_received {:brain_done, "the answer"}
    assert new_state.context_seq == 1, "no rotation once the brain is genuinely done"
  end

  # ---- tts: false — a quiet (typed) turn: the reply is read, never spoken, so there is no
  # Cartesia socket at all. Same owner-message contract as the spoken path. ----
  describe "tts: false" do
    # No transcript: nothing calls Gemini, so the process can be driven by hand exactly the
    # way its Gemini task would drive it.
    defp start_quiet do
      {:ok, pid} = BrainStream.start(owner: self(), config: %Config{}, tts: false)
      on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
      pid
    end

    test "never connects to Cartesia and is ready at once" do
      pid = start_quiet()
      state = :sys.get_state(pid)

      assert state.ready
      assert state.conn == nil
      assert state.websocket == nil
    end

    test "deltas reach the owner as brain_text, and done carries the accumulated answer" do
      pid = start_quiet()
      send(pid, {:gemini_delta, "it's "})
      send(pid, {:gemini_delta, "sunny"})
      send(pid, {:gemini_done})

      assert_receive {:brain_text, "it's "}, 500
      assert_receive {:brain_text, "sunny"}, 500
      assert_receive {:brain_done, "it's sunny"}, 500
      # stays alive like the spoken done path: the owner clears + terminates us
      assert Process.alive?(pid)
    end

    test "a bridge filler is dropped (nothing to speak it with) and never reaches the answer" do
      pid = start_quiet()
      send(pid, {:gemini_bridge, "one sec"})
      send(pid, {:gemini_delta, "done"})
      send(pid, {:gemini_done})

      assert_receive {:brain_done, "done"}, 500
      refute_received {:brain_text, "one sec"}
    end

    test "tool calls are still relayed, and an empty answer still finishes" do
      pid = start_quiet()
      send(pid, {:gemini_tool_call, "get_weather"})
      send(pid, {:gemini_done})

      assert_receive {:brain_tool_call, "get_weather"}, 500
      assert_receive {:brain_done, ""}, 500
    end

    test "a gemini error is reported as brain_error" do
      pid = start_quiet()
      ref = Process.monitor(pid)
      send(pid, {:gemini_error, {:http, 500}})

      assert_receive {:brain_error, {:http, 500}}, 500
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 500
    end
  end
end
