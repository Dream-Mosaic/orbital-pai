defmodule App.MemoryTest do
  use App.DataCase, async: false

  alias App.Memory
  alias App.Users

  setup do
    Application.put_env(:app, :allowed_users, [
      %{email: "d@x.com", name: "Alice"},
      %{email: "t@x.com", name: "Bob"}
    ])

    on_exit(fn -> Application.delete_env(:app, :allowed_users) end)
    {:ok, d} = Users.upsert_allowed("d@x.com")
    {:ok, t} = Users.upsert_allowed("t@x.com")
    %{d: d.id, t: t.id}
  end

  test "facts and summary are isolated per user", %{d: d, t: t} do
    {:ok, _} = Memory.create_fact(%{content: "Alice likes tea", source: "user", user_id: d})
    {:ok, _} = Memory.create_fact(%{content: "Bob likes coffee", source: "user", user_id: t})
    Memory.put_summary(t, "Bob summary")

    assert Enum.map(Memory.list_facts(d), & &1.content) == ["Alice likes tea"]
    assert Enum.map(Memory.list_facts(t), & &1.content) == ["Bob likes coffee"]
    assert Memory.get_summary(d).content == ""
    assert Memory.get_summary(t).content == "Bob summary"
  end

  test "recent_turns is scoped to the owning user", %{d: d, t: t} do
    {:ok, _} = Memory.persist_turn(%{user_id: d, user_text: "d-turn", brain_text: "b"})
    {:ok, _} = Memory.persist_turn(%{user_id: t, user_text: "t-turn", brain_text: "b"})

    assert Enum.map(Memory.recent_turns(d), & &1.user_text) == ["d-turn"]
    assert Enum.map(Memory.recent_turns(t), & &1.user_text) == ["t-turn"]
  end

  test "reset wipes only that user's turns/auto-facts/summary", %{d: d, t: t} do
    {:ok, _} = Memory.persist_turn(%{user_id: d, user_text: "hi", brain_text: "yo"})
    {:ok, _} = Memory.create_fact(%{content: "d auto", source: "auto", user_id: d})
    {:ok, _} = Memory.create_fact(%{content: "t auto", source: "auto", user_id: t})
    Memory.put_summary(d, "ds")

    Memory.reset(d)

    assert Memory.recent_turns(d) == []
    assert Memory.list_facts(d) == []
    assert Enum.map(Memory.list_facts(t), & &1.content) == ["t auto"]
    assert Memory.get_summary(d).content == ""
  end

  test "forget wipes one user's facts + summary + turns, leaving the other user", %{d: d, t: t} do
    {:ok, _} = Memory.create_fact(%{content: "d1", source: "user", user_id: d})
    {:ok, _} = Memory.create_fact(%{content: "d2", source: "auto", user_id: d})
    Memory.put_summary(d, "d summary")
    {:ok, _} = Memory.persist_turn(%{user_id: d, user_text: "d hi", brain_text: "d yo"})
    {:ok, _} = Memory.create_fact(%{content: "t1", source: "user", user_id: t})
    {:ok, _} = Memory.persist_turn(%{user_id: t, user_text: "t hi", brain_text: "t yo"})

    Memory.forget(d)

    assert Memory.list_facts(d) == []
    assert Memory.get_summary(d).content == ""
    # Wipe memory is a full amnesia — the conversation goes too (was left behind before).
    assert Memory.recent_turns(d) == []
    assert Enum.map(Memory.list_facts(t), & &1.content) == ["t1"]
    assert Enum.map(Memory.recent_turns(t), & &1.user_text) == ["t hi"]
  end

  test "persist_turn + recent_turns returns chronological, bounded history for the user", %{d: d} do
    for i <- 1..10,
        do:
          {:ok, _} =
            Memory.persist_turn(%{user_id: d, user_text: "u#{i}", brain_text: "b#{i}"})

    recent = Memory.recent_turns(d)
    # bounded to @recent_turns (8), oldest-first within the most-recent window
    assert length(recent) == 8
    assert hd(recent).user_text == "u3"
    assert List.last(recent).user_text == "u10"
  end

  test "prune_auto_facts caps auto-facts to N most recent and never touches user-source facts", %{
    d: d
  } do
    {:ok, _} = Memory.create_fact(%{content: "curated", source: "user", user_id: d})

    for i <- 1..5,
        do: {:ok, _} = Memory.create_fact(%{content: "auto #{i}", source: "auto", user_id: d})

    Memory.prune_auto_facts(d, 2)
    facts = Memory.list_facts(d)
    autos = facts |> Enum.filter(&(&1.source == "auto")) |> Enum.map(& &1.content)

    assert length(autos) == 2
    assert "auto 5" in autos and "auto 4" in autos
    assert Enum.any?(facts, &(&1.source == "user" and &1.content == "curated"))
  end

  test "context/2 assembles profile + summary + recent for the user", %{d: d} do
    sid = to_string(d)
    {:ok, _} = Memory.create_fact(%{content: "Alice likes tea", source: "user", user_id: d})
    Memory.put_summary(d, "knows Alice")
    {:ok, _} = Memory.persist_turn(%{user_id: d, user_text: "hi", brain_text: "hello"})

    ctx = Memory.context(sid)
    assert ctx.profile =~ "Alice likes tea"
    assert ctx.summary == "knows Alice"
    assert Enum.map(ctx.recent, & &1.user_text) == ["hi"]
  end

  test "context/2 with recent: false omits turns but keeps profile + summary", %{d: d} do
    sid = to_string(d)
    {:ok, _} = Memory.create_fact(%{content: "fact", source: "user", user_id: d})
    Memory.put_summary(d, "sum")
    {:ok, _} = Memory.persist_turn(%{user_id: d, user_text: "hi", brain_text: "hello"})

    ctx = Memory.context(sid, recent: false)
    assert ctx.recent == []
    assert ctx.profile =~ "fact"
    assert ctx.summary == "sum"
  end

  test "context includes the user's name", %{d: d} do
    user = Users.get(d)
    ctx = Memory.context(to_string(user.id))
    assert ctx.user_name == user.name
  end

  test "sessionless context has no user_name" do
    assert Memory.context("nope").user_name == nil
  end

  test "ProfileFact changeset requires content + user_id and validates source", %{d: d} do
    alias App.Memory.ProfileFact

    assert ProfileFact.changeset(%ProfileFact{}, %{content: "x", user_id: d, source: "user"}).valid?

    refute ProfileFact.changeset(%ProfileFact{}, %{user_id: d}).valid?
    refute ProfileFact.changeset(%ProfileFact{}, %{content: "x"}).valid?

    refute ProfileFact.changeset(%ProfileFact{}, %{content: "x", user_id: d, source: "bogus"}).valid?
  end

  describe "search_turns/3" do
    test "finds, scopes by user, limits, survives hostile queries", %{d: u1, t: u2} do
      for {uid, text} <- [
            {u1, "we talked about the tomato seedlings"},
            {u1, "drone flying weather tomorrow"},
            {u2, "tomato soup recipe"}
          ] do
        {:ok, _} =
          Memory.persist_turn(%{user_id: uid, user_text: text, brain_text: "noted"})
      end

      [hit] = Memory.search_turns(u1, "tomato")
      assert hit.you =~ "seedlings"
      assert hit.when =~ ~r/^\d{4}-\d{2}-\d{2}$/
      assert hit.henry == "noted"

      assert Memory.search_turns(u1, ~s|tomato "quoted" AND (weird|) != :error
      assert Memory.search_turns(u1, "") == []
    end
  end
end
