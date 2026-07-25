defmodule App.Adapters.Stt.CartesiaTest do
  use ExUnit.Case, async: true
  alias App.Adapters.Stt.Cartesia

  defp ev(map), do: Jason.encode!(map)

  test "path_for maps mode to the right Ink-2 endpoint" do
    assert Cartesia.path_for(:auto) == "/stt/turns/websocket"
    assert Cartesia.path_for(:manual) == "/stt/websocket"
  end

  # ---- auto (native turns) ----

  test "auto: turn.update previews the cumulative transcript; turn.end endpoints it" do
    acc = {[], ""}

    {m1, acc} = Cartesia.route(ev(%{"type" => "turn.update", "transcript" => "what's the"}), acc)
    assert m1 == {:stt_partial, "what's the"}

    {m2, acc} =
      Cartesia.route(ev(%{"type" => "turn.end", "transcript" => "what's the weather"}), acc)

    assert m2 == {:stt_endpoint, "what's the weather"}
    assert acc == {[], ""}
  end

  test "auto: connected is ignored" do
    acc = {[], ""}
    assert {nil, ^acc} = Cartesia.route(ev(%{"type" => "connected"}), acc)
  end

  test "auto: turn.start surfaces a bare onset signal, accumulator untouched" do
    assert {{:stt_turn_start}, {["seg"], "iv"}} =
             Cartesia.route(ev(%{"type" => "turn.start"}), {["seg"], "iv"})
  end

  test "auto: turn.eager_end surfaces the predicted transcript; empty is dropped; acc untouched" do
    acc = {[], ""}

    assert {{:stt_eager_end, "what's the weather"}, ^acc} =
             Cartesia.route(
               ev(%{"type" => "turn.eager_end", "transcript" => "what's the weather"}),
               acc
             )

    # the accumulator is NOT mutated — the real endpoint is still turn.end
    assert {{:stt_eager_end, "hi"}, {["seg"], "iv"}} =
             Cartesia.route(
               ev(%{"type" => "turn.eager_end", "transcript" => "hi"}),
               {["seg"], "iv"}
             )

    assert {nil, ^acc} =
             Cartesia.route(ev(%{"type" => "turn.eager_end", "transcript" => ""}), acc)
  end

  test "auto: turn.resume surfaces a bare resume signal, accumulator untouched" do
    assert {{:stt_resume}, {["seg"], "iv"}} =
             Cartesia.route(ev(%{"type" => "turn.resume"}), {["seg"], "iv"})
  end

  test "auto: non-JSON and unknown events are ignored, accumulator untouched" do
    assert {nil, {[], ""}} = Cartesia.route("not json", {[], ""})
    assert {nil, {["x"], "y"}} = Cartesia.route(ev(%{"type" => "whatever"}), {["x"], "y"})
  end

  test "auto: turn.end with empty transcript endpoints nothing" do
    assert {nil, {[], ""}} =
             Cartesia.route(ev(%{"type" => "turn.end", "transcript" => ""}), {[], ""})
  end

  # ---- manual (PTT, /stt/websocket: transcript + is_final + text) ----

  test "manual: interim previews; is_final commits a segment; flush_done ends the whole hold" do
    acc = {[], ""}

    {m1, acc} =
      Cartesia.route(ev(%{"type" => "transcript", "is_final" => false, "text" => "remind"}), acc)

    assert m1 == {:stt_partial, "remind"}

    {m2, acc} =
      Cartesia.route(
        ev(%{"type" => "transcript", "is_final" => true, "text" => "remind me"}),
        acc
      )

    assert m2 == {:stt_partial, "remind me"}
    assert acc == {["remind me"], ""}

    {m3, acc} =
      Cartesia.route(ev(%{"type" => "transcript", "is_final" => false, "text" => "at five"}), acc)

    assert m3 == {:stt_partial, "remind me at five"}

    {m4, acc} = Cartesia.route(ev(%{"type" => "flush_done"}), acc)
    assert m4 == {:stt_endpoint, "remind me at five"}
    assert acc == {[], ""}
  end

  test "manual: flush_done with only an interim (no is_final yet) still endpoints" do
    {_, acc} =
      Cartesia.route(
        ev(%{"type" => "transcript", "is_final" => false, "text" => "hello there"}),
        {[], ""}
      )

    assert {{:stt_endpoint, "hello there"}, {[], ""}} =
             Cartesia.route(ev(%{"type" => "flush_done"}), acc)
  end

  test "manual: an empty release (no speech) endpoints nothing" do
    assert {nil, {[], ""}} = Cartesia.route(ev(%{"type" => "flush_done"}), {[], ""})
  end

  test "manual: an empty transcript segment is ignored" do
    assert {nil, {[], ""}} =
             Cartesia.route(
               ev(%{"type" => "transcript", "is_final" => true, "text" => ""}),
               {[], ""}
             )
  end

  test "query_params carries model, encoding, and sample_rate" do
    p = Cartesia.query_params(%{sample_rate: 16_000, model: "ink-2"})
    assert p.model == "ink-2"
    assert p.encoding == "pcm_s16le"
    assert p.sample_rate == 16_000
  end
end
