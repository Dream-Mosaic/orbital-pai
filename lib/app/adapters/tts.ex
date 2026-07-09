defmodule App.Adapters.Tts do
  @moduledoc "text -> {:ok, pcm16_binary} (whole clip; the Conversation chunks + times it)."
  @callback synthesize(text :: String.t(), opts :: keyword()) ::
              {:ok, binary()} | {:error, term()}
end
