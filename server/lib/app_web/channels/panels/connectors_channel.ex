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

  Adding a connection, and reducing an account that holds two connectors down
  to one, both need Google's consent page — this panel cannot complete either
  flow itself. What it CAN do, same as the web (`conversation_live.ex:336-337`
  redirecting to `change_access_path/3`), is hand back the `/auth/google/connect`
  URL for that consent screen: `grant_url` for adding/changing a connector, and
  `disconnect`'s non-`only_grant` reply for a reduction. The native client opens
  that URL in the system browser; nothing local changes here — editing our
  stored scope locally would leave a live Google token holding more access than
  our record claims, so the actual scope change only ever happens via Google's
  consent flow completing back through `/auth/google/connect`. See spec §2.

  Three booleans are derived HERE because the web derives them there and the
  rules are not obvious to a client:

    * `shows_default` — the web's `connector_multi?/2` (`voice_modals.ex:522-523`)
    * `only_grant`    — decides whether Disconnect works natively at all
    * `access`        — `Connectors.access/2`, an atom, stringified for the wire
  """
  use AppWeb, :channel

  alias App.Google.{Accounts, Connectors, Grant}

  @impl true
  def join("panel:connectors:" <> _ignored, _payload, socket) do
    # The suffix is ignored; the user is whoever the token authenticated.
    send(self(), :push_state)
    {:ok, socket}
  end

  @impl true
  def handle_in("set_default", %{"account_id" => id}, socket) when is_integer(id) do
    case own_account(socket, id) do
      nil ->
        {:reply, {:error, %{reason: "bad_request"}}, socket}

      account ->
        case Accounts.set_default(account) do
          # set_default/1 does not broadcast (accounts.ex:32-38), so the fresh
          # state is pushed HERE. See the moduledoc.
          {:ok, _updated} -> {:reply, :ok, push_state(socket)}
          {:error, _reason} -> {:reply, {:error, %{reason: "bad_request"}}, socket}
        end
    end
  end

  def handle_in("disconnect", %{"account_id" => id, "connector" => conn}, socket)
      when is_integer(id) and is_binary(conn) do
    account = own_account(socket, id)
    connector = known_connector(conn)

    cond do
      is_nil(account) or is_nil(connector) ->
        {:reply, {:error, %{reason: "bad_request"}}, socket}

      # RE-DERIVED, every time. The payload's own `only_grant` — if a stale
      # client sends one — is never read: the panel that decided it may have
      # been rendered before this account gained a second connector, and the
      # cost of trusting it is deleting a Google connection the user still
      # wants. The web makes the same check at conversation_live.ex:332.
      Connectors.granted(account) != [connector] ->
        # Not a local no-op: this account holds more than just `connector`, so
        # deleting it would take those other grants with it. The fix is the
        # SAME consent screen `grant_url` uses — `Grant.path/3` on this
        # account with `connector` forced to `:none` — which Google will show
        # as "review the permissions this app is requesting" for the reduced
        # set. The native client opens it in the system browser; nothing local
        # changes until that flow completes back through `/auth/google/connect`.
        {:reply, {:ok, %{url: AppWeb.Endpoint.url() <> Grant.path(account, connector, :none)}},
         socket}

      true ->
        case Accounts.delete(account) do
          {:ok, _account} -> {:reply, :ok, push_state(socket)}
          {:error, _changeset} -> {:reply, {:error, %{reason: "bad_request"}}, socket}
        end
    end
  end

  def handle_in("grant_url", %{"connector" => conn, "fields" => fields}, socket)
      when is_binary(conn) and is_map(fields) do
    with connector when not is_nil(connector) <- known_connector(conn),
         level when not is_nil(level) <- known_level(connector, fields["level"]),
         {:ok, target} <- grant_target(socket, fields["account"]),
         path when is_binary(path) <- Grant.path(target, connector, level) do
      {:reply, {:ok, %{url: AppWeb.Endpoint.url() <> path}}, socket}
    else
      _ -> {:reply, {:error, %{reason: "bad_request"}}, socket}
    end
  end

  # A client bug — or a probe — must not crash the channel and drop the panel.
  @impl true
  def handle_in(_event, _payload, socket),
    do: {:reply, {:error, %{reason: "bad_request"}}, socket}

  @impl true
  def handle_info(:push_state, socket), do: {:noreply, push_state(socket)}

  # One query, reused for the rows AND for shows_default, so the two can never
  # disagree about which accounts exist.
  defp push_state(socket) do
    accounts = Accounts.list(socket.assigns.user_id)

    push(socket, "state", %{
      connections: Enum.map(rows(accounts), &row(&1, accounts)),
      catalog: catalog()
    })

    socket
  end

  # Describes HOW a connector is added, not just what it is. `kind` says how the flow
  # completes (`oauth_redirect` is the only one implemented); `fields` is the form the
  # client renders. Adding a connector to the registry makes it appear in the app with
  # no Dart change — which is the entire reason the form is generic. See spec §5.
  defp catalog do
    for c <- Connectors.all() do
      %{
        key: Atom.to_string(c),
        label: Connectors.label(c),
        provider: "google",
        kind: "oauth_redirect",
        fields: [
          %{name: "account", label: "Account", type: "account_select", required: true},
          %{
            name: "level",
            label: "Access",
            type: "choice",
            required: true,
            options:
              for lvl <- Connectors.access_levels(c) do
                %{value: Atom.to_string(lvl), label: Atom.to_string(lvl)}
              end
          }
        ]
      }
    end
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

  # Both ids on this channel are CLIENT-SUPPLIED. Resolved against this user's
  # own accounts — never Repo.get, never the topic suffix. Accounts.list/1 is
  # already `where: a.user_id == ^user_id` (accounts.ex:13-14), so a foreign id
  # simply is not in the list.
  defp own_account(socket, id),
    do: Enum.find(Accounts.list(socket.assigns.user_id), &(&1.id == id))

  # A LITERAL allowlist walk over the registry — NOT String.to_existing_atom/1,
  # which is no guard at all here: :calendar, :gmail, :email, :id, :scope and
  # :refresh_token are all already-existing atoms in this VM. Walking
  # Connectors.all/0 (connectors.ex:31-32) means the allowlist widens by itself
  # when the registry gains a connector, and cannot widen any other way.
  # Returns nil for anything unknown; the caller turns that into bad_request.
  defp known_connector(name),
    do: Enum.find(Connectors.all(), &(Atom.to_string(&1) == name))

  # Same literal-walk rule as known_connector/1, and for the same reason:
  # String.to_existing_atom/1 is not a guard here either — :read, :write and
  # :none are all already-existing atoms in this VM, so it would happily turn
  # ANY existing atom name into a "known" level. Walking
  # Connectors.access_levels/1 means only levels the registry actually offers
  # for THIS connector can ever match. Returns nil for anything unknown
  # (including a non-binary `level`, which no `Atom.to_string/1` result equals).
  defp known_level(connector, level),
    do: Enum.find(Connectors.access_levels(connector), &(Atom.to_string(&1) == level))

  # "new" requests a fresh account (nothing to preserve); any other value must
  # resolve to one of THIS user's own accounts — never Repo.get, never trust
  # an id that doesn't appear in Accounts.list/1's result.
  defp grant_target(_socket, "new"), do: {:ok, :new}

  defp grant_target(socket, id) do
    case own_account(socket, id) do
      nil -> :error
      account -> {:ok, account}
    end
  end
end
