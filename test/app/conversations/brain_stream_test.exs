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
end
