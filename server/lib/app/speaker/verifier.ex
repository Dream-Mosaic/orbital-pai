defmodule App.Speaker.Verifier do
  @moduledoc "Speaker-embedding backend. Swapped for a fake in tests via app env :speaker_verifier."
  @callback embed(pcm16 :: binary()) :: {:ok, [float()]} | {:error, term()}
  @callback ready?() :: boolean()
end
