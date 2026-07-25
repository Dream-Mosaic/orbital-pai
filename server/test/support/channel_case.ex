defmodule AppWeb.ChannelCase do
  @moduledoc """
  Test case for channels. Brings in `Phoenix.ChannelTest` helpers
  (`socket/3`, `subscribe_and_join/3`, `push/3`, `assert_push/2`, `leave/1`)
  and sets up the Ecto sandbox (harmless for channel tests that don't touch the DB).
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest
      import AppWeb.ChannelCase

      @endpoint AppWeb.Endpoint
    end
  end

  setup tags do
    App.DataCase.setup_sandbox(tags)
    :ok
  end
end
