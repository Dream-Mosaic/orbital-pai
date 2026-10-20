defmodule App.Toolkits.Toolkit do
  @moduledoc """
  A toolkit: a suite of tools the brain opens on demand (`use_toolkit`) instead of carrying
  every integration's declarations on every turn. The catalog line in the system prompt lists
  the enabled kits by `id` + `summary`; opening one adds its `tools` for the rest of the turn.
  `wants?/2` lets a kit pre-open itself when the user's words obviously need it.
  """

  @doc "Short lowercase name the brain passes to `use_toolkit`."
  @callback id() :: String.t()
  @doc "One phrase for the catalog line: what this kit covers."
  @callback summary() :: String.t()
  @doc "Is this kit usable under `config`?"
  @callback enabled?(config :: map()) :: boolean()
  @doc "The `App.Tools.Tool` modules this kit contributes."
  @callback tools() :: [module()]
  @doc "How to use the kit; returned to the brain when it opens the kit."
  @callback guidance() :: String.t()
  @doc "Optional: do the window `text` (and `ctx`) clearly need this kit? Over-opening beats under-opening."
  @callback wants?(text :: String.t(), ctx :: map()) :: boolean()
  @optional_callbacks wants?: 2
end
