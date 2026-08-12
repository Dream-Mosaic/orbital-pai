defmodule AppWeb.Panels.SettingsChannelTest do
  # async: false — SQLite is single-writer and these tests write users.
  use AppWeb.ChannelCase, async: false

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

  defp join!(socket, user), do: subscribe_and_join(socket, "panel:settings:#{user.id}", %{})

  test "join pushes the full pref set", %{socket: socket, alice: alice} do
    {:ok, _reply, _socket} = join!(socket, alice)

    assert_push "state", state
    assert is_boolean(state.default_abi)
    assert is_boolean(state.default_ptt)
    assert is_boolean(state.voice_activation)
    assert is_integer(state.relock_seconds)
    assert state.app_version == App.version()
  end

  test "briefing_time is nil when the morning briefing is off", %{socket: socket, alice: alice} do
    {:ok, _} = Users.update_prefs(alice, %{briefing_time: nil})
    {:ok, _reply, _socket} = join!(socket, alice)
    assert_push "state", %{briefing_time: nil}
  end

  test "briefing_time carries the stored time when it is on", %{socket: socket, alice: alice} do
    {:ok, _} = Users.update_prefs(alice, %{briefing_time: "07:30"})
    {:ok, _reply, _socket} = join!(socket, alice)
    assert_push "state", %{briefing_time: "07:30"}
  end

  test "the state is the TOKEN's user, not the topic's", %{socket: socket, alice: alice, bob: bob} do
    {:ok, _} = Users.update_prefs(alice, %{relock_seconds: 11})
    {:ok, _} = Users.update_prefs(bob, %{relock_seconds: 29})

    # Alice's socket asking for Bob's topic still gets Alice's prefs.
    {:ok, _reply, _socket} = subscribe_and_join(socket, "panel:settings:#{bob.id}", %{})
    assert_push "state", %{relock_seconds: 11}
  end

  test "the pushed state has exactly the six expected keys, no others", %{
    socket: socket,
    alice: alice
  } do
    {:ok, _reply, _socket} = join!(socket, alice)

    assert_push "state", state

    assert Map.keys(state) |> Enum.sort() ==
             Enum.sort([
               :default_abi,
               :default_ptt,
               :voice_activation,
               :briefing_time,
               :relock_seconds,
               :app_version
             ])
  end

  describe "set_pref" do
    test "each allowlisted pref round-trips", %{socket: socket, alice: alice} do
      {:ok, _reply, socket} = join!(socket, alice)
      assert_push "state", _

      for pref <- ~w(default_abi default_ptt voice_activation) do
        ref = push(socket, "set_pref", %{"pref" => pref, "value" => false})
        assert_reply ref, :ok
        assert_push "state", state
        refute Map.fetch!(state, String.to_existing_atom(pref))

        ref = push(socket, "set_pref", %{"pref" => pref, "value" => true})
        assert_reply ref, :ok
        assert_push "state", state
        assert Map.fetch!(state, String.to_existing_atom(pref))
      end

      assert Users.get(alice.id).default_abi
    end

    test "a pref outside the allowlist is refused and changes nothing",
         %{socket: socket, alice: alice} do
      # "books_last_book", "email" and "id" are all EXISTING atoms and
      # prefs_changeset/2 casts books_last_book — so String.to_existing_atom/1
      # alone would let these through. The guard must be a literal list.
      {:ok, _reply, socket} = join!(socket, alice)
      assert_push "state", _

      for pref <- ~w(books_last_book voice_lock_mode email id nonsense) do
        ref = push(socket, "set_pref", %{"pref" => pref, "value" => true})
        assert_reply ref, :error, %{reason: "bad_request"}
      end

      after_ = Users.get(alice.id)
      assert after_.books_last_book == alice.books_last_book
      assert after_.email == alice.email
    end

    test "a non-boolean value is refused", %{socket: socket, alice: alice} do
      {:ok, _reply, socket} = join!(socket, alice)
      assert_push "state", _

      # "1" and "0" are deliberately included: Ecto's own :boolean cast
      # coerces those strings to true/false (verified via
      # Ecto.Type.cast(:boolean, "1") == {:ok, true}), so prefs_changeset
      # alone would accept them — only the is_boolean/1 guard in handle_in
      # catches them. "yes" is caught by the changeset regardless, so it
      # alone would not prove the guard is doing anything.
      for bad <- ["yes", "1", "0"] do
        ref = push(socket, "set_pref", %{"pref" => "default_abi", "value" => bad})
        assert_reply ref, :error, %{reason: "bad_request"}
      end
    end
  end

  describe "set_relock" do
    test "stores the seconds and clamps both ends", %{socket: socket, alice: alice} do
      {:ok, _reply, socket} = join!(socket, alice)
      assert_push "state", _

      ref = push(socket, "set_relock", %{"seconds" => 22})
      assert_reply ref, :ok
      assert_push "state", %{relock_seconds: 22}

      ref = push(socket, "set_relock", %{"seconds" => 3})
      assert_reply ref, :ok
      assert_push "state", %{relock_seconds: 10}

      ref = push(socket, "set_relock", %{"seconds" => 900})
      assert_reply ref, :ok
      assert_push "state", %{relock_seconds: 30}

      assert Users.get(alice.id).relock_seconds == 30
    end

    test "reaches a LIVE conversation in milliseconds", %{socket: socket, alice: alice} do
      sid = to_string(alice.id)
      {:ok, pid} = App.Conversations.Sessions.start(sid, self())
      on_exit(fn -> App.Conversations.Sessions.stop(sid) end)

      {:ok, _reply, socket} = join!(socket, alice)
      assert_push "state", _

      ref = push(socket, "set_relock", %{"seconds" => 20})
      assert_reply ref, :ok
      assert_push "state", %{relock_seconds: 20}

      # set_relock_ms/2 is a cast; let it land, then read the FSM's own state.
      # 20 SECONDS must arrive as 20_000 ms — a test that only checked the
      # stored integer would pass with the `* 1000` missing.
      Process.sleep(50)
      assert :sys.get_state(pid) |> elem(1) |> Map.get(:relock_ms) == 20_000
    end

    test "with no live session it still stores and replies ok",
         %{socket: socket, alice: alice} do
      {:ok, _reply, socket} = join!(socket, alice)
      assert_push "state", _

      ref = push(socket, "set_relock", %{"seconds" => 17})
      assert_reply ref, :ok
      assert_push "state", %{relock_seconds: 17}
    end

    test "a non-integer is refused", %{socket: socket, alice: alice} do
      {:ok, _reply, socket} = join!(socket, alice)
      assert_push "state", _

      ref = push(socket, "set_relock", %{"seconds" => "20"})
      assert_reply ref, :error, %{reason: "bad_request"}
    end
  end

  describe "set_briefing" do
    test "a time turns the briefing on; nil turns it off",
         %{socket: socket, alice: alice} do
      {:ok, _reply, socket} = join!(socket, alice)
      assert_push "state", _

      ref = push(socket, "set_briefing", %{"time" => "06:45"})
      assert_reply ref, :ok
      assert_push "state", %{briefing_time: "06:45"}

      ref = push(socket, "set_briefing", %{"time" => nil})
      assert_reply ref, :ok
      assert_push "state", %{briefing_time: nil}
      refute Users.get(alice.id).briefing_time
    end

    test "a malformed time is refused", %{socket: socket, alice: alice} do
      {:ok, _reply, socket} = join!(socket, alice)
      assert_push "state", _

      for bad <- ["7:00", "25:00", "07:60", "0700", "seven", ""] do
        ref = push(socket, "set_briefing", %{"time" => bad})
        assert_reply ref, :error, %{reason: "bad_request"}
      end

      refute Users.get(alice.id).briefing_time == "seven"
    end
  end
end
