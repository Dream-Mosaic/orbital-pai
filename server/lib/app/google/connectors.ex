defmodule App.Google.Connectors do
  @moduledoc """
  The connector registry and pure access/scope resolution for Google.

  Each connector declares a read scope and a write scope (write implies read). An account's
  access to a connector is **derived from the granted scope string** stored on the account — the
  single source of truth — so there is no separate grants table. `scopes_for/1` turns a desired
  grant map (e.g. `%{calendar: :write}`) into the scopes to request at (re)connect.
  """
  alias App.Google.Account

  @connectors %{
    calendar: %{
      label: "Google Calendar",
      read: "https://www.googleapis.com/auth/calendar.readonly",
      write: "https://www.googleapis.com/auth/calendar.events"
    },
    gmail: %{
      label: "Gmail",
      read: "https://www.googleapis.com/auth/gmail.readonly",
      write: "https://www.googleapis.com/auth/gmail.send"
    }
  }

  # openid + email are always requested so we can identify the connected account (id_token email).
  @base_scopes ["openid", "email"]

  # Display/iteration order for connectors (stable as the registry grows; keep in sync with @connectors).
  @connector_order [:calendar, :gmail]

  @doc "All connector keys, in stable display order."
  def all, do: @connector_order

  @doc """
  Selectable access levels for a connector, in display order (lowest→highest). Google connectors
  offer the full tri-state; a connector could later offer a subset (e.g. read-only).
  """
  def access_levels(_conn), do: [:none, :read, :write]

  @doc "Registry entry for a connector (raises on unknown key — keys are compile-time)."
  def fetch(conn), do: Map.fetch!(@connectors, conn)

  @doc "Human label for a connector."
  def label(conn), do: fetch(conn).label

  @doc "Access level for an account on a connector: `:none | :read | :write` (write implies read)."
  def access(%Account{scope: scope}, conn) do
    c = fetch(conn)
    granted = scope_set(scope)

    cond do
      MapSet.member?(granted, c.write) -> :write
      MapSet.member?(granted, c.read) -> :read
      true -> :none
    end
  end

  defp scope_set(scope) do
    (scope || "") |> String.split() |> MapSet.new()
  end

  def can_read?(account, conn), do: access(account, conn) in [:read, :write]
  def can_write?(account, conn), do: access(account, conn) == :write

  @doc "Connectors this account has any (read or write) access to, in stable display order."
  def granted(account),
    do: Enum.filter(all(), &(access(account, &1) != :none))

  @doc """
  Scopes to request for a desired grant map. `:read` requests the read scope; `:write` requests
  read + write (so Write is a strict superset of Read on the wire). Always includes openid + email.
  """
  def scopes_for(grants) when is_map(grants) do
    conn_scopes =
      Enum.flat_map(grants, fn
        {_conn, :none} -> []
        {conn, :read} -> [fetch(conn).read]
        {conn, :write} -> [fetch(conn).read, fetch(conn).write]
      end)

    Enum.uniq(@base_scopes ++ conn_scopes)
  end

  @doc "Every read/write scope across the registry."
  def all_connector_scopes do
    Enum.flat_map(all(), fn conn ->
      c = fetch(conn)
      [c.read, c.write]
    end)
  end

  @doc """
  True when `requested_scopes` would drop a connector scope the account currently holds (a Write→Read
  downgrade or a removed connector). Reductions can't be done incrementally — Google accumulates
  granted scopes — so the caller must revoke then reconnect.
  """
  def reduction?(current_scope, requested_scopes) do
    granted = scope_set(current_scope)
    requested = MapSet.new(requested_scopes)

    all_connector_scopes()
    |> Enum.filter(&MapSet.member?(granted, &1))
    |> Enum.any?(&(not MapSet.member?(requested, &1)))
  end
end
