defmodule App.Adapters.TextModel do
  @moduledoc "transcript + memory context -> reply text. Reflex and brain both implement this."
  @callback generate(transcript :: String.t(), ctx :: map(), opts :: keyword()) ::
              {:ok, String.t()} | {:error, term()}
end
