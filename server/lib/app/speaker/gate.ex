defmodule App.Speaker.Gate do
  @moduledoc """
  Pure Voice-Lock turn decision (the Policy of this feature — no processes, no clock).
  Short turns (< min_verify_ms of turn audio) skip embedding entirely and ride the
  trust window; longer turns are decided by cosine score vs the enrolled voiceprint.
  Fail-open (verifier down/timeout/no voiceprint) is the CALLER's job — never encode
  a pass-by-default here.
  """

  @type reason :: :verified | :trusted | :below_threshold | :short_no_trust

  @spec decide(map()) :: {:pass | :drop, reason()}
  def decide(%{speech_ms: speech_ms} = p) when speech_ms < :erlang.map_get(:min_verify_ms, p) do
    case p.last_verified_ms_ago do
      nil -> {:drop, :short_no_trust}
      ago when ago <= :erlang.map_get(:trust_window_ms, p) -> {:pass, :trusted}
      _ -> {:drop, :short_no_trust}
    end
  end

  def decide(%{score: score, threshold: threshold}) when is_number(score) do
    if score >= threshold, do: {:pass, :verified}, else: {:drop, :below_threshold}
  end

  @doc "Cosine of two L2-normalized vectors (plain dot product)."
  @spec score([float()], [float()]) :: float()
  def score(a, b) when length(a) == length(b) do
    Enum.zip(a, b) |> Enum.reduce(0.0, fn {x, y}, s -> s + x * y end)
  end
end
