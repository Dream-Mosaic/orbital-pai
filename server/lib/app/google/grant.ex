defmodule App.Google.Grant do
  @moduledoc """
  Builds the `/auth/google/connect` path for a desired grant.

  Lives outside the LiveView because it is about to have two callers — the LiveView's connectors
  panel and the upcoming `AppWeb.Panels.ConnectorsChannel` (native client) — the same situation
  that put `AppWeb.BookFormat` and `AppWeb.ReminderFormat` outside `AppWeb.VoiceModals`. A
  previous phase extracted display strings for exactly that reason, and a final review still
  found one function left copy-pasted between the LiveView and the channel — with a concrete
  scenario where the app and the web would open on different data for the same user, while every
  test passed, because each surface was tested against its own copy. An extraction that stops one
  function short produces exactly the divergence it was meant to prevent, so this module owns the
  URL rule once for both callers.

  The rule that matters: changing one connector's access must never silently reduce another's.
  An existing account's path is built by rebuilding its ENTIRE connector→access map (read back
  from its granted scopes via `Connectors.access/2`), overriding just the connector being
  changed, then dropping `:none` entries and appending `account=<id>`.
  """

  alias App.Google.{Account, Connectors}

  @doc """
  Path that grants `level` on `connector`.

  For a NEW account (`:new`) this requests only that connector — there is nothing else on the
  account to preserve. For an EXISTING `%Account{}` it rebuilds the account's whole
  connector→access map with `connector` overridden, drops `:none` entries, and carries
  `account=<id>` — so changing one connector never silently reduces another.

  `nil` for the one no-op the web also refuses: a new account requesting `:none`.
  """
  def path(:new, _connector, :none), do: nil

  def path(:new, connector, level),
    do:
      "/auth/google/connect?" <>
        URI.encode_query(%{Atom.to_string(connector) => Atom.to_string(level)})

  def path(%Account{} = account, connector, level) do
    query =
      Connectors.all()
      |> Map.new(fn c -> {c, Connectors.access(account, c)} end)
      |> Map.put(connector, level)
      |> Enum.reject(fn {_c, lvl} -> lvl == :none end)
      |> Enum.map(fn {c, lvl} -> {Atom.to_string(c), Atom.to_string(lvl)} end)
      |> Map.new()
      |> Map.put("account", account.id)
      |> URI.encode_query()

    "/auth/google/connect?" <> query
  end
end
