defmodule AppWeb.Presence do
  @moduledoc "Live voice-session presence (who is actively connected, and from what)."
  use Phoenix.Presence, otp_app: :app, pubsub_server: App.PubSub
end
