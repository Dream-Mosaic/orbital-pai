defmodule AppWeb.Panels.VoiceLockChannelTest do
  # async: false — SQLite is single-writer and these tests write users/gate events.
  use AppWeb.ChannelCase, async: false

  alias App.Speaker
  alias App.Users

  setup do
    Application.put_env(:app, :allowed_users, [
      %{email: "alice@x.com", name: "Alice"},
      %{email: "bob@x.com", name: "Bob"}
    ])

    on_exit(fn -> Application.delete_env(:app, :allowed_users) end)
    {:ok, alice} = Users.upsert_allowed("alice@x.com")
    {:ok, bob} = Users.upsert_allowed("bob@x.com")
    token = AppWeb.UserAuth.socket_token(alice.id)
    {:ok, socket} = connect(AppWeb.UserSocket, %{"token" => token})
    %{socket: socket, alice: alice, bob: bob}
  end

  defp join!(socket, user), do: subscribe_and_join(socket, "panel:voice_lock:#{user.id}", %{})

  defp loud_frames(seconds) do
    for _ <- 1..(seconds * 10), do: for(_ <- 1..1_600, into: <<>>, do: <<1000::16-signed-little>>)
  end

  test "join pushes user_id, mode, enrolled_slots, verifier_ready, drops",
       %{socket: socket, alice: alice} do
    {:ok, _reply, _socket} = join!(socket, alice)

    assert_push "state", state
    assert state.user_id == alice.id
    assert state.mode == "off"
    assert state.enrolled_slots == []
    assert state.verifier_ready == true
    assert state.drops == []
  end

  test "mode is the raw string \"off\" for a fresh user", %{socket: socket, alice: alice} do
    {:ok, _reply, _socket} = join!(socket, alice)
    assert_push "state", %{mode: "off"}
  end

  test "user_id is the TOKEN user's integer id", %{socket: socket, alice: alice} do
    {:ok, _reply, _socket} = join!(socket, alice)
    assert_push "state", %{user_id: uid}
    assert uid == alice.id
    assert is_integer(uid)
  end

  test "enrolled_slots reflects App.Speaker.enroll_clip/3", %{socket: socket, alice: alice} do
    pcm = loud_frames(7) |> IO.iodata_to_binary()
    :ok = Speaker.enroll_clip(alice.id, 1, pcm)

    {:ok, _reply, _socket} = join!(socket, alice)
    assert_push "state", %{enrolled_slots: [1]}
  end

  test "verifier_ready is false when the verifier reports not-ready",
       %{socket: socket, alice: alice} do
    Application.put_env(:app, :fake_verifier_ready, false)
    on_exit(fn -> Application.delete_env(:app, :fake_verifier_ready) end)

    {:ok, _reply, _socket} = join!(socket, alice)
    assert_push "state", %{verifier_ready: false}
  end

  test "a drop row carries exactly decision, transcript, score",
       %{socket: socket, alice: alice} do
    :ok =
      Speaker.log_event(%{
        user_id: alice.id,
        decision: "drop",
        transcript: "hey there",
        score: 0.5,
        mode: "enforce"
      })

    {:ok, _reply, _socket} = join!(socket, alice)
    assert_push "state", %{drops: [row]}
    assert Map.keys(row) |> Enum.sort() == Enum.sort([:decision, :transcript, :score])
  end

  test "a null score crosses as null", %{socket: socket, alice: alice} do
    :ok =
      Speaker.log_event(%{
        user_id: alice.id,
        decision: "would_drop",
        transcript: "hi",
        score: nil,
        mode: "shadow"
      })

    {:ok, _reply, _socket} = join!(socket, alice)
    assert_push "state", %{drops: [row]}
    assert %{score: nil} = row
  end

  test "drops are newest first and only drop/would_drop decisions appear",
       %{socket: socket, alice: alice} do
    :ok =
      Speaker.log_event(%{
        user_id: alice.id,
        decision: "drop",
        transcript: "first",
        score: 0.1,
        mode: "enforce"
      })

    :ok =
      Speaker.log_event(%{
        user_id: alice.id,
        decision: "pass",
        transcript: "ignored",
        score: 0.9,
        mode: "enforce"
      })

    :ok =
      Speaker.log_event(%{
        user_id: alice.id,
        decision: "would_drop",
        transcript: "second",
        score: 0.2,
        mode: "shadow"
      })

    {:ok, _reply, _socket} = join!(socket, alice)
    assert_push "state", %{drops: drops}
    assert Enum.map(drops, & &1.transcript) == ["second", "first"]
  end

  test "the state is the TOKEN's user, not the topic's", %{socket: socket, alice: alice, bob: bob} do
    # Alice's socket asking for Bob's topic still gets Alice's user_id.
    {:ok, _reply, _socket} = join!(socket, bob)
    assert_push "state", %{user_id: uid}
    assert uid == alice.id
  end

  test "set_mode with \"shadow\" persists and a fresh state arrives via the broadcast",
       %{socket: socket, alice: alice} do
    {:ok, _reply, socket} = join!(socket, alice)
    assert_push "state", %{mode: "off"}

    ref = push(socket, "set_mode", %{"mode" => "shadow"})
    assert_reply ref, :ok

    assert Users.get(alice.id).voice_lock_mode == "shadow"
    assert_push "state", %{mode: "shadow"}
  end

  test "exactly ONE state push follows a set_mode", %{socket: socket, alice: alice} do
    {:ok, _reply, socket} = join!(socket, alice)
    assert_push "state", _

    ref = push(socket, "set_mode", %{"mode" => "enforce"})
    assert_reply ref, :ok
    assert_push "state", %{mode: "enforce"}
    refute_push "state", _, 200
  end

  test "an invalid mode is bad_request, changes nothing, and the channel survives",
       %{socket: socket, alice: alice} do
    {:ok, _reply, socket} = join!(socket, alice)
    assert_push "state", %{mode: "off"}

    for payload <- [%{"mode" => "ENFORCE"}, %{"mode" => "admin"}, %{"mode" => 123}, %{}] do
      ref = push(socket, "set_mode", payload)
      assert_reply ref, :error, %{reason: "bad_request"}
    end

    assert Users.get(alice.id).voice_lock_mode == "off"

    ref = push(socket, "set_mode", %{"mode" => "shadow"})
    assert_reply ref, :ok
    assert_push "state", %{mode: "shadow"}
  end

  test "an unknown event is bad_request and the channel survives",
       %{socket: socket, alice: alice} do
    {:ok, _reply, socket} = join!(socket, alice)
    assert_push "state", %{mode: "off"}

    ref = push(socket, "bogus_event", %{})
    assert_reply ref, :error, %{reason: "bad_request"}

    ref2 = push(socket, "set_mode", %{"mode" => "shadow"})
    assert_reply ref2, :ok
    assert_push "state", %{mode: "shadow"}
  end
end
