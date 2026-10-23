defmodule App.Conversations.ScopeTest do
  # async: false — a session-bound Conversation runs DB pulls right after init (shared
  # sandbox), and one test flips the global Logger level.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias App.Conversations.{Conversation, Scope}

  # Spec 2026-10-23-wall-tablet-design, phase 4: the scope follows the BOUND device. The
  # Conversation is one per user, so "any joined device is shared" would leak household scope
  # onto the same user's phone (review finding C1, July).

  setup do
    App.DataCase.setup_sandbox(%{async: false})
    %{sid: "scope-#{System.unique_integer([:positive])}"}
  end

  # Registered under `sid` exactly as Sessions.start/3 registers it, so the published value is
  # the one Scope.current/1 reads. The client defaults to the test process.
  defp start_session(sid, client \\ self()) do
    {:ok, pid} =
      Conversation.start_link(
        client: client,
        config: %App.Config{},
        session_id: sid,
        name: {:via, Registry, {App.Conversations.Registry, sid}}
      )

    pid
  end

  # Synchronous, so the init pulls can't outlive the sandbox owner (see conversation_test.exs).
  defp stop_session(pid) do
    App.DataCase.drain_conversation_tasks()
    :gen_statem.stop(pid, :normal, 2_000)
  end

  # A call orders after every cast this process sent before it.
  defp sync(pid), do: Conversation.snapshot(pid)

  defp role(pid, from, shared), do: :gen_statem.cast(pid, {:device_role, from, role(shared)})
  defp role(shared), do: %{kiosk: shared, shared: shared}

  defp idle_client do
    spawn(fn -> receive do: (:stop -> :ok) end)
  end

  test "no session, or no live conversation, is personal" do
    assert Scope.current(nil) == :personal
    assert Scope.current("nobody-#{System.unique_integer([:positive])}") == :personal
  end

  test "a session with no device role is personal", %{sid: sid} do
    pid = start_session(sid)
    Conversation.join(pid, "phone")
    sync(pid)

    assert Scope.current(sid) == :personal
    stop_session(pid)
  end

  test "the bound device declaring itself shared makes the session household", %{sid: sid} do
    pid = start_session(sid)
    Conversation.join(pid, "wall")
    Conversation.device_role(pid, %{kiosk: true, shared: true})
    sync(pid)

    assert Scope.current(sid) == :household

    # ...and switching Shared off on the wall takes effect without a rejoin
    Conversation.device_role(pid, %{kiosk: true, shared: false})
    sync(pid)
    assert Scope.current(sid) == :personal
    stop_session(pid)
  end

  # VoiceChannel sends the role ahead of the join, so a wall's reconnect binds straight into
  # household instead of flipping through personal for the instant between the two casts.
  test "a role sent BEFORE the join is in force the moment that channel binds", %{sid: sid} do
    gone = spawn(fn -> :ok end)
    ref = Process.monitor(gone)
    assert_receive {:DOWN, ^ref, :process, ^gone, _}
    # nothing live holds the conversation, so the wall's join binds
    pid = start_session(sid, gone)

    wall = idle_client()
    role(pid, wall, true)
    # a role on a channel that isn't bound changes nothing yet
    sync(pid)
    assert Scope.current(sid) == :personal

    :gen_statem.cast(pid, {:join, wall, "wall"})

    assert %{bound_device: "wall"} = sync(pid)
    assert Scope.current(sid) == :household
    stop_session(pid)
  end

  test "a phone that claims while the wall is bound is personal; the wall claiming back is household",
       %{sid: sid} do
    pid = start_session(sid)
    # the test process is the wall
    Conversation.join(pid, "wall")
    Conversation.device_role(pid, %{kiosk: true, shared: true})

    phone = idle_client()
    :gen_statem.cast(pid, {:join, phone, "phone"})
    role(pid, phone, false)
    sync(pid)
    assert Scope.current(sid) == :household

    :gen_statem.cast(pid, {:ptt_press, phone})
    assert %{bound_device: "phone"} = sync(pid)
    assert Scope.current(sid) == :personal

    Conversation.wake_detected(pid)
    assert %{bound_device: "wall"} = sync(pid)
    assert Scope.current(sid) == :household
    stop_session(pid)
  end

  test "a standby shared device does not make a personal session household", %{sid: sid} do
    pid = start_session(sid)
    Conversation.join(pid, "phone")
    Conversation.device_role(pid, %{kiosk: false, shared: false})

    wall = idle_client()
    :gen_statem.cast(pid, {:join, wall, "wall"})
    role(pid, wall, true)
    sync(pid)

    assert Scope.current(sid) == :personal
    stop_session(pid)
  end

  test "the bound shared channel leaving drops the session back to personal", %{sid: sid} do
    pid = start_session(sid)
    Conversation.join(pid, "wall")
    Conversation.device_role(pid, %{kiosk: true, shared: true})
    sync(pid)
    assert Scope.current(sid) == :household

    Conversation.client_disconnected(pid, self())
    sync(pid)
    assert Scope.current(sid) == :personal
    stop_session(pid)
  end

  test "a bound shared channel that dies without a clean disconnect drops to personal",
       %{sid: sid} do
    wall = idle_client()
    pid = start_session(sid, wall)
    role(pid, wall, true)
    sync(pid)
    assert Scope.current(sid) == :household

    Process.exit(wall, :kill)
    assert wait_until(fn -> Scope.current(sid) == :personal end)
    stop_session(pid)
  end

  test "an older client that never sends shared stays personal", %{sid: sid} do
    pid = start_session(sid)
    Conversation.join(pid, "wall")
    Conversation.device_role(pid, %{kiosk: true})
    sync(pid)

    assert Scope.current(sid) == :personal
    stop_session(pid)
  end

  test "the scope change is logged once per change, with no user content", %{sid: sid} do
    level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: level) end)

    pid = start_session(sid)

    log =
      capture_log([level: :info], fn ->
        Conversation.join(pid, "wall")
        Conversation.device_role(pid, %{kiosk: true, shared: true})
        # a repeat push of the same role is not a change
        Conversation.device_role(pid, %{kiosk: true, shared: true})
        Conversation.client_disconnected(pid, self())
        sync(pid)
      end)

    assert [_] = Regex.scan(~r/\[scope\] household \(bound device is shared\)/, log)
    assert [_] = Regex.scan(~r/\[scope\] personal/, log)
    stop_session(pid)
  end

  defp wait_until(fun, retries \\ 50) do
    cond do
      fun.() -> true
      retries == 0 -> false
      true -> Process.sleep(10) && wait_until(fun, retries - 1)
    end
  end
end
