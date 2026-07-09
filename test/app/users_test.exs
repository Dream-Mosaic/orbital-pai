defmodule App.UsersTest do
  use App.DataCase, async: false

  alias App.Users

  setup do
    Application.put_env(:app, :allowed_users, [
      %{email: "alice@x.com", name: "Alice"},
      %{email: "bob@x.com", name: "Bob"}
    ])

    on_exit(fn -> Application.delete_env(:app, :allowed_users) end)
  end

  test "allowed? is case-insensitive and rejects non-allowlisted emails" do
    assert Users.allowed?("ALICE@x.com")
    assert Users.allowed?("bob@x.com")
    refute Users.allowed?("stranger@x.com")
    refute Users.allowed?(nil)
  end

  test "upsert_allowed creates an allowlisted user (downcased) with the configured name" do
    assert {:ok, u} = Users.upsert_allowed("Alice@x.com")
    assert u.email == "alice@x.com"
    assert u.name == "Alice"

    assert {:ok, u2} = Users.upsert_allowed("alice@x.com")
    assert u2.id == u.id
    assert length(Users.list()) == 1
  end

  test "upsert_allowed rejects a non-allowlisted email" do
    assert {:error, :not_allowed} = Users.upsert_allowed("stranger@x.com")
    assert Users.list() == []
  end

  test "ensure_allowlisted seeds every allowlisted user and returns the primary (first)" do
    primary = Users.ensure_allowlisted()
    assert primary.email == "alice@x.com"
    assert Enum.map(Users.list(), & &1.email) |> Enum.sort() == ["alice@x.com", "bob@x.com"]

    Users.ensure_allowlisted()
    assert length(Users.list()) == 2
  end

  test "update_prefs/2 persists default_abi and default_ptt" do
    {:ok, user} = App.Users.upsert_allowed("alice@x.com")
    assert user.default_abi == false
    assert user.default_ptt == false

    {:ok, updated} = App.Users.update_prefs(user, %{default_abi: true, default_ptt: true})
    assert updated.default_abi == true
    assert updated.default_ptt == true
    # persisted, not just in-memory
    assert App.Users.get(user.id).default_abi == true
  end

  test "update_prefs persists voice_activation" do
    user =
      %App.Users.User{}
      |> App.Users.User.changeset(%{email: "va@x.com", name: "VA Tester"})
      |> App.Repo.insert!()

    {:ok, updated} = App.Users.update_prefs(user, %{voice_activation: true})
    assert updated.voice_activation == true
  end

  test "update_prefs persists relock_seconds" do
    {:ok, user} = Users.upsert_allowed("alice@x.com")
    {:ok, updated} = Users.update_prefs(user, %{relock_seconds: 22})
    assert updated.relock_seconds == 22
  end

  test "any alias email authenticates into the same canonical user (one row)" do
    Application.put_env(:app, :allowed_users, [
      %{email: "alice@x.com", name: "Alice", aliases: ["dave@y.com", "d@z.com"]}
    ])

    assert Users.allowed?("dave@y.com")
    assert Users.allowed?("D@Z.com")
    refute Users.allowed?("stranger@x.com")

    {:ok, u1} = Users.upsert_allowed("alice@x.com")
    {:ok, u2} = Users.upsert_allowed("dave@y.com")
    {:ok, u3} = Users.upsert_allowed("D@Z.com")

    # all three logins resolve to the SAME row, keyed by the canonical email
    assert u1.id == u2.id
    assert u2.id == u3.id
    assert u1.email == "alice@x.com"
    assert length(Users.list()) == 1
  end

  describe "briefing prefs" do
    test "briefing_time accepts HH:MM, clears on nil, rejects garbage" do
      {:ok, user} = Users.upsert_allowed("alice@x.com")
      assert {:ok, u} = Users.update_prefs(user, %{briefing_time: "07:00"})
      assert u.briefing_time == "07:00"
      assert {:ok, u} = Users.update_prefs(u, %{briefing_time: nil})
      assert u.briefing_time == nil
      assert {:error, _} = Users.update_prefs(user, %{briefing_time: "7am"})
    end

    test "list_briefing_users/0 returns only users with a briefing_time" do
      {:ok, on} = Users.upsert_allowed("alice@x.com")
      {:ok, _off} = Users.upsert_allowed("bob@x.com")
      {:ok, on} = Users.update_prefs(on, %{briefing_time: "07:00"})
      assert Enum.map(Users.list_briefing_users(), & &1.id) == [on.id]
    end

    test "stamp_briefing!/2 records the delivered date" do
      {:ok, user} = Users.upsert_allowed("alice@x.com")
      stamped = Users.stamp_briefing!(user, ~D[2026-07-03])
      assert stamped.briefing_last_on == ~D[2026-07-03]
    end
  end

  describe "stamp_briefing! busy-retry (with_busy_retry/2)" do
    # The briefing's once/day claim is stamped at delivery off the FSM in an ack task. SQLite is
    # single-writer, so that stamp can transiently hit "Database is busy"; it's the briefing's ONLY
    # cross-session dedup, so a lost stamp would risk a repeated briefing — hence the retry.
    test "retries a transient SQLite 'Database is busy' then returns the success value" do
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      result =
        Users.with_busy_retry(fn ->
          n = Agent.get_and_update(calls, &{&1, &1 + 1})
          if n == 0, do: raise(%Exqlite.Error{message: "Database is busy"}), else: :stamped
        end)

      assert result == :stamped
      assert Agent.get(calls, & &1) == 2
    end

    test "does not retry a non-busy error — reraises immediately" do
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      assert_raise RuntimeError, "nope", fn ->
        Users.with_busy_retry(fn ->
          Agent.update(calls, &(&1 + 1))
          raise "nope"
        end)
      end

      assert Agent.get(calls, & &1) == 1
    end
  end
end
