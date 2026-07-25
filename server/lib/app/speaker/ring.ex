defmodule App.Speaker.Ring do
  @moduledoc """
  Rolling mic-PCM buffer for Voice Lock: newest-first iolist of frames + byte counts —
  no copying until slice. `mark/1` pins the turn.start position; `slice/3` returns the
  turn's audio (mark minus pre-roll, capped at max_bytes from the END) plus speech_ms
  (bytes since mark / 32 — the spec's proxy for speech length, pre-roll excluded).
  """
  defstruct frames: [], bytes: 0, total: 0, cap: 0, mark: nil

  @bytes_per_ms 32

  def new(cap_bytes), do: %__MODULE__{cap: cap_bytes}

  def push(%__MODULE__{} = r, frame) when is_binary(frame) do
    r = %{
      r
      | frames: [frame | r.frames],
        bytes: r.bytes + byte_size(frame),
        total: r.total + byte_size(frame)
    }

    trim(r)
  end

  defp trim(%{bytes: b, cap: cap} = r) when b <= cap, do: r

  defp trim(r) do
    {kept, dropped} = drop_last(r.frames, r.bytes - r.cap)
    %{r | frames: kept, bytes: r.bytes - dropped}
  end

  # drop whole frames from the OLD end (tail of the newest-first list) until >= excess dropped
  defp drop_last(frames, excess) do
    {rev, dropped} =
      frames
      |> Enum.reverse()
      |> Enum.reduce({[], 0}, fn f, {acc, d} ->
        if d >= excess, do: {[f | acc], d}, else: {acc, d + byte_size(f)}
      end)

    {Enum.reverse(rev), dropped}
  end

  def mark(%__MODULE__{} = r), do: %{r | mark: r.total}
  def clear_mark(%__MODULE__{} = r), do: %{r | mark: nil}

  def slice(%__MODULE__{mark: nil}, _preroll, _max), do: :no_mark

  def slice(%__MODULE__{} = r, preroll_bytes, max_bytes) do
    turn_bytes = r.total - r.mark
    want = min(min(turn_bytes + preroll_bytes, max_bytes), r.bytes)
    bin = take_newest(r.frames, want)
    {:ok, bin, div(turn_bytes, @bytes_per_ms)}
  end

  defp take_newest(frames, want) do
    {taken, _} =
      Enum.reduce_while(frames, {[], 0}, fn f, {acc, got} ->
        if got >= want, do: {:halt, {acc, got}}, else: {:cont, {[f | acc], got + byte_size(f)}}
      end)

    bin = IO.iodata_to_binary(taken)
    if byte_size(bin) > want, do: binary_part(bin, byte_size(bin) - want, want), else: bin
  end
end
