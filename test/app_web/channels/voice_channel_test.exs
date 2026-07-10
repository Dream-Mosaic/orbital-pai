defmodule AppWeb.VoiceChannelTest do
  # async: false — the inbound test registers a global observer name, and the
  # Conversation runs in a supervised process (not the test's sandbox owner).
  use AppWeb.ChannelCase, async: false

  alias App.Conversations.Sessions
  alias App.Users
  alias App.Repo

  setup do
    Application.put_env(:app, :allowed_users, [
      %{email: "alice@x.com", name: "Alice"},
      %{email: "bob@x.com", name: "Bob"}
    ])

    on_exit(fn -> Application.delete_env(:app, :allowed_users) end)
    {:ok, alice} = Users.upsert_allowed("alice@x.com")
    {:ok, bob} = Users.upsert_allowed("bob@x.com")

    sid = to_string(alice.id)
    token = AppWeb.UserAuth.socket_token(alice.id)
    {:ok, socket} = connect(AppWeb.UserSocket, %{"token" => token})
    {:ok, _reply, socket} = subscribe_and_join(socket, "voice:#{sid}", %{})

    on_exit(fn -> Sessions.stop(sid) end)
    %{socket: socket, alice: alice, bob: bob, sid: sid}
  end

  test "connect refuses a missing/garbage token" do
    assert :error = connect(AppWeb.UserSocket, %{})
    assert :error = connect(AppWeb.UserSocket, %{"token" => "nope"})
  end

  test "connect refuses a token whose user no longer exists", %{alice: alice} do
    token = AppWeb.UserAuth.socket_token(alice.id)
    Repo.delete!(alice)
    assert :error = connect(AppWeb.UserSocket, %{"token" => token})
  end

  test "a socket authed as Alice binds Alice's session regardless of the client topic", %{
    alice: alice,
    bob: bob
  } do
    token = AppWeb.UserAuth.socket_token(alice.id)
    {:ok, socket} = connect(AppWeb.UserSocket, %{"token" => token})

    {:ok, _reply, channel} = subscribe_and_join(socket, "voice:#{bob.id}", %{})
    assert channel.assigns.session_id == to_string(alice.id)
    on_exit(fn -> Sessions.stop(to_string(alice.id)) end)
  end

  test "join starts a session bound to this channel", %{sid: sid} do
    assert {:ok, pid} = Sessions.lookup(sid)
    assert Process.alive?(pid)
  end

  test "join pushes a state snapshot" do
    # The setup block's join already delivered this — a fresh session starts
    # listening/unlocked, and every (re)bind (including the first) pushes a snapshot.
    assert_push "state", %{phase: "listening", locked: false}
  end

  test "joining with a live session REBINDS instead of restarting it", %{sid: sid, alice: alice} do
    {:ok, pid} = Sessions.lookup(sid)

    token = AppWeb.UserAuth.socket_token(alice.id)
    {:ok, socket2} = connect(AppWeb.UserSocket, %{"token" => token})
    {:ok, _reply, _channel2} = subscribe_and_join(socket2, "voice:#{sid}", %{})

    # same pid — state preserved (a restart would hand back a fresh pid)
    assert {:ok, ^pid} = Sessions.lookup(sid)
  end

  test "terminate does not kill a session another channel rebound", %{
    socket: socket_a,
    sid: sid,
    alice: alice
  } do
    {:ok, pid} = Sessions.lookup(sid)
    ref = Process.monitor(pid)

    token = AppWeb.UserAuth.socket_token(alice.id)
    {:ok, socket_b} = connect(AppWeb.UserSocket, %{"token" => token})
    {:ok, _reply, _channel_b} = subscribe_and_join(socket_b, "voice:#{sid}", %{})

    # channel A closes, but it's no longer the bound client (B rebound it) — terminate's
    # client_disconnected is pid-guarded, so this must NOT arm the linger/stop.
    Process.flag(:trap_exit, true)
    reply_ref = leave(socket_a)
    assert_reply reply_ref, :ok

    refute_receive {:DOWN, ^ref, :process, ^pid, _}, 200
    assert Process.alive?(pid)
    assert {:ok, ^pid} = Sessions.lookup(sid)
  end

  test "relays speak_start to the browser", %{socket: socket} do
    send(socket.channel_pid, {:to_client, {:speak_start, :reflex, "hi there"}})
    assert_push "speak_start", %{source: :reflex, text: "hi there"}
  end

  test "relays live partial transcripts to the browser", %{socket: socket} do
    send(socket.channel_pid, {:to_client, {:partial, "hello wor"}})
    assert_push "partial", %{text: "hello wor"}
  end

  test "relays a brain_delta to the browser", %{socket: socket} do
    send(socket.channel_pid, {:to_client, {:brain_delta, "the "}})
    assert_push "brain_delta", %{delta: "the "}
  end

  test "audio relays as a binary payload", %{socket: socket} do
    send(socket.channel_pid, {:to_client, {:audio, :brain, <<1, 2, 3, 4>>}})
    assert_push "audio", {:binary, <<1, 2, 3, 4>>}
  end

  test "relays metrics to the browser", %{socket: socket} do
    send(socket.channel_pid, {:to_client, {:metrics, 320, 1400}})
    assert_push "metrics", %{ttfa: 320, ttb: 1400}
  end

  test "relays stop_playback to the browser", %{socket: socket} do
    send(socket.channel_pid, {:to_client, :stop_playback})
    assert_push "stop_playback", %{}
  end

  test "relays thinking to the browser", %{socket: socket} do
    send(socket.channel_pid, {:to_client, :thinking})
    assert_push "thinking", %{}
  end

  test "inbound mic audio reaches the session STT", %{socket: socket} do
    Process.register(self(), :fake_stt_observer)
    pcm = <<1, 2, 3, 4>>
    push(socket, "audio", {:binary, pcm})
    assert_receive {:fake_stt_push, ^pcm}
  end

  test "inbound barge_in is forwarded without crashing the channel", %{socket: socket} do
    push(socket, "barge_in", %{})
    # channel is still responsive afterward
    send(socket.channel_pid, {:to_client, :stop_playback})
    assert_push "stop_playback", %{}
  end

  test "an inbound allow_interruptions toggle is handled without crashing the channel",
       %{socket: socket} do
    push(socket, "allow_interruptions", %{"enabled" => true})
    # channel stays responsive afterward
    send(socket.channel_pid, {:to_client, :stop_playback})
    assert_push "stop_playback", %{}
  end

  test "an inbound ptt_release finalizes the STT", %{socket: socket} do
    Process.register(self(), :fake_stt_observer)

    on_exit(fn ->
      if Process.whereis(:fake_stt_observer), do: Process.unregister(:fake_stt_observer)
    end)

    push(socket, "ptt_release", %{})
    assert_receive {:fake_stt_finalize}, 1000
  end

  test "PTT events flow through the channel", %{socket: socket} do
    Process.register(self(), :fake_stt_observer)

    on_exit(fn ->
      if Process.whereis(:fake_stt_observer), do: Process.unregister(:fake_stt_observer)
    end)

    push(socket, "ptt", %{"enabled" => true})
    assert_receive {:fake_stt_started, :manual}, 1000
    push(socket, "ptt_press", %{})
    push(socket, "ptt_release", %{})
    assert_receive {:fake_stt_finalize}, 1000
  end

  test "leaving arms the linger and the session dies after it expires (tears down STT)", %{
    socket: socket,
    sid: sid
  } do
    # W2: a channel closing no longer stops the session outright — it only disconnects the
    # client, which arms a linger for a rebind. Shrink the linger so this test doesn't wait 120s.
    Application.put_env(:app, :client_linger_ms, 50)
    on_exit(fn -> Application.delete_env(:app, :client_linger_ms) end)

    # The channel is linked to us; leaving exits it with {:shutdown, :left}.
    Process.flag(:trap_exit, true)
    {:ok, conv} = Sessions.lookup(sid)
    ref = Process.monitor(conv)

    reply_ref = leave(socket)
    assert_reply reply_ref, :ok

    assert_receive {:DOWN, ^ref, :process, ^conv, _}, 500
    refute Process.alive?(conv)
    # Registry clears the session entry asynchronously after the process dies.
    assert wait_until(fn -> Sessions.lookup(sid) == :error end)
  end

  defp wait_until(fun, retries \\ 50) do
    cond do
      fun.() -> true
      retries == 0 -> false
      true -> Process.sleep(10) && wait_until(fun, retries - 1)
    end
  end
end
