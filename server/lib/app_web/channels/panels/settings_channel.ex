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

  @impl true
  def handle_info(:push_state, socket), do: {:noreply, push_state(socket)}

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
