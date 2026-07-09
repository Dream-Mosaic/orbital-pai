defmodule App.Conversations.SessionsTest do
  use ExUnit.Case, async: false
  alias App.Conversations.Sessions

  defp eventually(_fun, 0), do: false

  defp eventually(fun, n) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, n - 1)
    end
  end

  test "start registers a live conversation; stop tears it down" do
    sid = "sess-#{System.unique_integer([:positive])}"
    {:ok, pid} = Sessions.start(sid, self())
    assert {:ok, ^pid} = Sessions.lookup(sid)
    assert Process.alive?(pid)

    assert :ok = Sessions.stop(sid)
    assert eventually(fn -> not Process.alive?(pid) end, 50)
    assert eventually(fn -> Sessions.lookup(sid) == :error end, 50)
  end

  test "duplicate session id errors" do
    sid = "dup-#{System.unique_integer([:positive])}"
    {:ok, _pid} = Sessions.start(sid, self())
    assert {:error, {:already_started, _}} = Sessions.start(sid, self())
    Sessions.stop(sid)
  end
end
