defmodule App.Memory.ConsolidatorTest do
  use App.DataCase, async: false
  import Mox

  alias App.Memory
  alias App.Memory.Consolidator

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    Application.put_env(:app, :allowed_users, [%{email: "gardener@x.com", name: "David"}])
    on_exit(fn -> Application.delete_env(:app, :allowed_users) end)
    {:ok, user} = App.Users.upsert_allowed("gardener@x.com")
    %{user: user}
  end

  test "window?/1" do
    assert Consolidator.window?(~T[03:30:00])
    refute Consolidator.window?(~T[12:00:00])
    refute Consolidator.window?(~T[05:00:01])
  end

  test "a run digests yesterday, merges auto facts, rebuilds the summary; second run no-ops", %{
    user: user
  } do
    yesterday = Date.add(Date.utc_today(), -1)

    # a turn from yesterday (backdate inserted_at directly)
    {:ok, turn} =
      Memory.persist_turn(%{user_id: user.id, user_text: "planted tomatoes", brain_text: "noted"})

    backdate = DateTime.new!(yesterday, ~T[15:00:00], "Etc/UTC")

    Repo.update_all(from(t in Memory.Turn, where: t.id == ^turn.id), set: [inserted_at: backdate])

    # duplicate-ish auto facts + one user fact that must survive untouched
    {:ok, _} = Memory.create_fact(%{user_id: user.id, content: "likes tomatoes", source: "auto"})

    {:ok, _} =
      Memory.create_fact(%{user_id: user.id, content: "enjoys tomatoes a lot", source: "auto"})

    {:ok, _} = Memory.create_fact(%{user_id: user.id, content: "wife is Tanya", source: "user"})

    # 3 model calls: digest, fact merge, summary rebuild — keyed on prompt content
    stub(App.TextModelMock, :generate, fn prompt, _ctx, _opts ->
      cond do
        prompt =~ "single ~100-word digest" -> {:ok, "Planted tomatoes and planned the garden."}
        prompt =~ "Merge and deduplicate" -> {:ok, "likes tomatoes"}
        prompt =~ "Rebuild the memory" -> {:ok, "David gardens; tomatoes planted."}
        true -> {:ok, "NONE"}
      end
    end)

    assert :ok = Consolidator.run_user(user.id, Date.utc_today())

    assert [%{content: "Planted tomatoes and planned the garden."}] =
             Memory.digests_for(user.id, 3)

    facts = Memory.list_facts(user.id)
    auto = Enum.filter(facts, &(&1.source == "auto"))
    assert Enum.map(auto, & &1.content) == ["likes tomatoes"]
    assert Enum.any?(facts, &(&1.source == "user" and &1.content == "wife is Tanya"))
    assert Memory.get_summary(user.id).content == "David gardens; tomatoes planted."

    # idempotent: the digest row claims the day
    assert :ok = Consolidator.run_user(user.id, Date.utc_today())
    assert length(Memory.digests_for(user.id, 10)) == 1
  end
end
