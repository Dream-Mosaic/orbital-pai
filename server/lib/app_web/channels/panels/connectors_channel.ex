defmodule AppWeb.Panels.ConnectorsChannel do
  @moduledoc """
  The native Connectors drawer's data path. Joined only while that drawer is
  open — it is a bottom-nav station in its own right (`MeridianTab.connectors`),
  like Reminders, not a layer inside Settings.

  Non-essential: a refusal stops this channel and leaves the conversation alone.

  This channel PUSHES `state` FROM ITS HANDLERS, like `AppWeb.Panels.SettingsChannel`
  and unlike `MemoryChannel`/`VoiceLockChannel`. That is not a style choice — it
  was read, not assumed, before this file was written:

    * `App.Google.Accounts.set_default/1` (`accounts.ex:32-38`) — a bare
      `Repo.transaction`. No broadcast.
    * `App.Google.Accounts.delete/1` (`accounts.ex:103-106`) — a semantic purge
      plus `Repo.delete`. No broadcast.
    * `grep -rn "PubSub" lib/app/google/` — zero hits.

  There is therefore nothing to ride. Do NOT "fix" this into a subscription
  without adding a broadcast to `App.Google.Accounts` first. The cost, exactly
  as on `SettingsChannel`, is that a connection changed on the WEB while this
  drawer is open is not seen until the drawer is reopened — acceptable for two
  surfaces one person uses at a time.

  What this panel deliberately CANNOT do is anything that needs Google's consent
  page: adding a connection, and reducing an account that holds two connectors
  down to one. The web implements the latter as a re-consent with fewer scopes
  (`conversation_live.ex:336-337` redirects to `change_access_path/3`), because
  editing our stored scope locally would leave a live Google token holding more
  access than our record claims. `disconnect` therefore refuses with
  `needs_web` rather than faking it; see spec §2.

  Three booleans are derived HERE because the web derives them there and the
  rules are not obvious to a client:

    * `shows_default` — the web's `connector_multi?/2` (`voice_modals.ex:522-523`)
    * `only_grant`    — decides whether Disconnect works natively at all
    * `access`        — `Connectors.access/2`, an atom, stringified for the wire
  """
  use AppWeb, :channel

  alias App.Google.{Accounts, Connectors}

  @impl true
  def join("panel:connectors:" <> _ignored, _payload, socket) do
    # The suffix is ignored; the user is whoever the token authenticated.
    send(self(), :push_state)
    {:ok, socket}
  end

  # A client bug — or a probe — must not crash the channel and drop the panel.
  # Task 2 adds the write clauses ABOVE this one.
  @impl true
  def handle_in(_event, _payload, socket),
    do: {:reply, {:error, %{reason: "bad_request"}}, socket}

  @impl true
  def handle_info(:push_state, socket), do: {:noreply, push_state(socket)}

  # One query, reused for the rows AND for shows_default, so the two can never
  # disagree about which accounts exist.
  defp push_state(socket) do
    accounts = Accounts.list(socket.assigns.user_id)
    push(socket, "state", %{connections: Enum.map(rows(accounts), &row(&1, accounts))})
    socket
  end

  # The web's connection_rows/1 (voice_modals.ex:517-520), verbatim. Sorted by
  # {label, email} SERVER-SIDE — the client never re-sorts, so this is the only
  # place the order is decided.
  defp rows(accounts) do
    for(a <- accounts, conn <- Connectors.granted(a), do: {conn, a})
    |> Enum.sort_by(fn {conn, a} -> {Connectors.label(conn), a.email} end)
  end

  # EXACTLY eight keys — never the %Account{} struct, which carries
  # refresh_token, access_token and the raw scope string (account.ex:6-16).
  defp row({conn, a}, accounts) do
    %{
      account_id: a.id,
      email: a.email,
      connector: Atom.to_string(conn),
      label: Connectors.label(conn),
      # Connectors.access/2 returns an ATOM; the wire gets a string.
      access: Atom.to_string(Connectors.access(a, conn)),
      is_default: a.is_default,
      shows_default: multi?(accounts, conn),
      # Connectors.granted/1 returns display order, so a single-element list
      # compares cleanly. This is the value the client MUST NOT re-derive: it
      # is what decides whether Disconnect deletes or defers to the browser.
      only_grant: Connectors.granted(a) == [conn]
    }
  end

  # The web's connector_multi?/2 (voice_modals.ex:522-523), verbatim: the
  # default badge/button only appears once at least TWO accounts can reach this
  # connector, because with one there is nothing to choose between.
  defp multi?(accounts, connector),
    do: Enum.count(accounts, &(Connectors.access(&1, connector) != :none)) >= 2
end
