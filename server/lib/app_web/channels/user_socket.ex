defmodule AppWeb.UserSocket do
  @moduledoc "Voice transport. Authenticated via a Phoenix.Token carrying the user id."
  use Phoenix.Socket

  channel "voice:*", AppWeb.VoiceChannel
  channel "enroll:*", AppWeb.EnrollChannel
  channel "badges:*", AppWeb.BadgesChannel
  channel "panel:reminders:*", AppWeb.Panels.RemindersChannel
  channel "panel:settings:*", AppWeb.Panels.SettingsChannel
  channel "panel:memory:*", AppWeb.Panels.MemoryChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    case AppWeb.UserAuth.authenticate_socket(token) do
      %App.Users.User{} = user -> {:ok, assign(socket, :user_id, user.id)}
      nil -> :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: "user_socket:#{socket.assigns.user_id}"
end
