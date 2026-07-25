defmodule App do
  @moduledoc """
  App keeps the contexts that define your domain
  and business logic.

  Contexts are also responsible for managing your data, regardless
  if it comes from the database, an external API or others.
  """

  @doc "The running app version, from the mix.exs version field, e.g. 0.2.0"
  def version, do: :app |> Application.spec(:vsn) |> to_string()
end
