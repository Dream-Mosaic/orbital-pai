defmodule App.SupervisionTest do
  use ExUnit.Case, async: true

  test "core conversation processes are started" do
    assert Process.whereis(App.Finch)
    assert Process.whereis(App.Conversations.Registry)
    assert Process.whereis(App.Conversations.TaskSup)
    assert Process.whereis(App.Conversations.Sup)
  end
end
