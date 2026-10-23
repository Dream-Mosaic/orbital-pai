defmodule App.Adapters.TextModel do
  @moduledoc "transcript + memory context -> reply text. Reflex and brain both implement this."
  @callback generate(transcript :: String.t(), ctx :: map(), opts :: keyword()) ::
              {:ok, String.t()} | {:error, term()}

  @doc """
  One photo + the user's question -> what the vision model sees ("Henry, look at this").
  `opts` carries `:config` (`App.Config`).
  """
  @callback describe_image(jpeg :: binary(), question :: String.t(), opts :: keyword()) ::
              {:ok, String.t()} | {:error, term()}
end
