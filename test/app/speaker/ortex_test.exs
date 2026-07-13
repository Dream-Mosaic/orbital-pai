defmodule App.Speaker.OrtexTest do
  use ExUnit.Case, async: false

  @model Application.compile_env(:app, :speaker_model_path, "priv/models/speaker_ecapa.onnx")
  @dir "test/support/fixtures/speaker"

  unless File.exists?(@model), do: @moduletag(:skip)

  test "embeds the fixture clip to match the python reference (cosine > 0.99)" do
    start_supervised!(App.Speaker.Ortex)
    pcm = App.Test.SpeakerFixtures.read_pcm("a1.wav")
    assert App.Speaker.Ortex.ready?()
    assert {:ok, emb} = App.Speaker.Ortex.embed(pcm)

    ref =
      Path.join(@dir, "emb_ref.bin") |> File.read!() |> Nx.from_binary(:f32) |> Nx.to_flat_list()

    cos = Enum.zip(emb, ref) |> Enum.reduce(0.0, fn {a, b}, s -> s + a * b end)
    assert cos > 0.99
  end

  test "not ready + embed error when the model file is missing" do
    Application.put_env(:app, :speaker_model_path, "priv/models/nope.onnx")
    on_exit(fn -> Application.delete_env(:app, :speaker_model_path) end)
    start_supervised!(App.Speaker.Ortex)
    refute App.Speaker.Ortex.ready?()
    assert {:error, :model_not_loaded} = App.Speaker.Ortex.embed(<<0, 0>>)
  end
end
