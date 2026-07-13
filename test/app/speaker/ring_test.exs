defmodule App.Speaker.RingTest do
  use ExUnit.Case, async: true
  alias App.Speaker.Ring

  # 32 bytes = 1ms of 16k PCM16
  defp frame(ms, byte \\ 1), do: :binary.copy(<<byte, byte>>, ms * 16)

  test "push trims to cap; slice without a mark is :no_mark" do
    ring = Enum.reduce(1..10, Ring.new(100 * 32), fn _, r -> Ring.push(r, frame(20)) end)
    assert ring.bytes <= 120 * 32
    assert Ring.slice(ring, 0, 1_000_000) == :no_mark
  end

  test "mark + slice returns audio since the mark plus pre-roll, capped, with speech_ms" do
    ring = Ring.new(10_000 * 32)
    # 500ms pre-turn
    ring = Enum.reduce(1..5, ring, fn _, r -> Ring.push(r, frame(100, 7)) end)
    ring = Ring.mark(ring)
    # 2000ms turn
    ring = Enum.reduce(1..20, ring, fn _, r -> Ring.push(r, frame(100, 9)) end)

    assert {:ok, bin, 2_000} = Ring.slice(ring, 300 * 32, 60_000 * 32)
    # 300ms pre-roll + 2000ms turn
    assert byte_size(bin) == 2_300 * 32

    # cap wins when the turn is longer than max_bytes
    assert {:ok, bin2, 2_000} = Ring.slice(ring, 300 * 32, 1_000 * 32)
    assert byte_size(bin2) == 1_000 * 32

    assert Ring.slice(Ring.clear_mark(ring), 0, 1_000) == :no_mark
  end
end
