defmodule App.Adapters.Tts.CartesiaTest do
  use ExUnit.Case, async: true
  alias App.Adapters.Tts.Cartesia

  test "generation_config omits emotion when nil/blank, includes it when set" do
    assert Cartesia.generation_config(1.2, 0.8, nil) == %{speed: 1.2, volume: 0.8}
    assert Cartesia.generation_config(1.0, 1.0, "") == %{speed: 1.0, volume: 1.0}

    assert Cartesia.generation_config(1.0, 1.0, "confident") ==
             %{speed: 1.0, volume: 1.0, emotion: "confident"}
  end

  test "build_body wires generation_config and drops the deprecated top-level speed" do
    opts = [
      voice_id: "v1",
      tts_speed: 1.25,
      tts_volume: 1.1,
      tts_emotion: "confident",
      sample_rate: 16_000,
      model: "sonic-2"
    ]

    body = Cartesia.build_body("hello", opts)

    refute Map.has_key?(body, :speed)
    assert body.transcript == "hello"
    assert body.voice == %{mode: "id", id: "v1"}
    assert body.generation_config == %{speed: 1.25, volume: 1.1, emotion: "confident"}
    assert body.output_format.sample_rate == 16_000
  end
end
