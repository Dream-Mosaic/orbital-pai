defmodule AppWeb.Panels.SettingsChannel do
  @moduledoc """
  The native Settings drawer's data path. Joined only while the drawer is open.

  Non-essential (B1 spec §5.1): a refusal here stops this channel and leaves the
  conversation and its socket alone.

  UNLIKE `AppWeb.Panels.RemindersChannel`, the write handlers push `state`
  themselves. `App.Users.update_prefs/2` does not broadcast, so there is no
  PubSub message to ride — do not "fix" this into a subscription without adding
  a broadcast first. The cost is that a pref changed on the web while this
  drawer is open is not seen until the drawer is reopened, which is acceptable
  for two surfaces one person uses at a time.
  """
  use AppWeb, :channel

  alias App.Users

  @impl true
  def join("panel:settings:" <> _ignored, _payload, socket) do
    # The suffix is ignored; the user is whoever the token authenticated.
    send(self(), :push_state)
    {:ok, socket}
  end

  # The ONLY prefs a client may set. A literal list, not `String.to_existing_atom/1`:
  # "email", "id" and "books_last_book" are all existing atoms, and
  # `User.prefs_changeset/2` casts books_last_book, voice_lock_mode and
  # voice_lock_threshold — so an atom-existence check would be no guard at all.
  @settable %{
    "default_abi" => :default_abi,
    "default_ptt" => :default_ptt,
    "voice_activation" => :voice_activation
  }

  @impl true
  def handle_in("set_pref", %{"pref" => pref, "value" => value}, socket)
      when is_binary(pref) and is_boolean(value) do
    case Map.fetch(@settable, pref) do
      {:ok, key} -> reply_write(write(socket, %{key => value}))
      :error -> {:reply, {:error, %{reason: "bad_request"}}, socket}
    end
  end

  def handle_in("set_briefing", %{"time" => nil}, socket),
    do: reply_write(write(socket, %{briefing_time: nil}))

  def handle_in("set_briefing", %{"time" => time}, socket) when is_binary(time) do
    if time =~ ~r/^([01]\d|2[0-3]):[0-5]\d$/ do
      reply_write(write(socket, %{briefing_time: time}))
    else
      {:reply, {:error, %{reason: "bad_request"}}, socket}
    end
  end

  # A client bug must not crash the channel and drop the panel.
  def handle_in(_event, _payload, socket),
    do: {:reply, {:error, %{reason: "bad_request"}}, socket}

  @impl true
  def handle_info(:push_state, socket), do: {:noreply, push_state(socket)}

  defp reply_write({:ok, socket}), do: {:reply, :ok, socket}

  # Unreachable with today's @settable: is_boolean(value) plus the set_briefing
  # regex (a strict subset of the schema's own HH:MM validate_format) mean every
  # attrs map that reaches write/2 casts cleanly, so update_prefs/2 never fails
  # here. Kept so the NEXT @settable addition (e.g. voice_lock_threshold, which
  # prefs_changeset/2 validates as a cosine in (-1, 1)) can't silently reply :ok
  # and push stale state on a write the changeset actually rejected.
  defp reply_write({:error, socket}), do: {:reply, {:error, %{reason: "bad_request"}}, socket}

  # Persist, then push the fresh state — but only on a successful write. See the
  # moduledoc for why the handler pushes rather than riding a broadcast.
  defp write(socket, attrs) do
    user = Users.get(socket.assigns.user_id)

    case Users.update_prefs(user, attrs) do
      {:ok, _user} -> {:ok, push_state(socket)}
      {:error, _changeset} -> {:error, socket}
    end
  end

  defp push_state(socket) do
    user = Users.get(socket.assigns.user_id)

    push(socket, "state", %{
      default_abi: user.default_abi,
      default_ptt: user.default_ptt,
      voice_activation: user.voice_activation,
      briefing_time: user.briefing_time,
      relock_seconds: user.relock_seconds,
      app_version: App.version()
    })

    socket
  end
end
