defmodule App.Memory.UpdaterTest do
  use App.DataCase, async: false
  import Mox
  alias App.Memory
  alias App.Memory.Updater
  alias App.Users

  setup :verify_on_exit!

  setup do
    Application.put_env(:app, :allowed_users, [%{email: "bobby@x.com", name: "Bobby"}])
    on_exit(fn -> Application.delete_env(:app, :allowed_users) end)
    {:ok, user} = Users.upsert_allowed("bobby@x.com")
    %{uid: user.id, sid: to_string(user.id)}
  end

  # run/1 makes two model calls: the summary, then the fact extraction. Route by prompt.
  defp stub_model(summary: summary, facts: facts) do
    stub(App.TextModelMock, :generate, fn prompt, _ctx, opts ->
      assert Keyword.fetch!(opts, :tier) == :memory
      if prompt =~ "Extract NEW durable facts", do: {:ok, facts}, else: {:ok, summary}
    end)
  end

  test "run/1 writes a model-produced summary", %{uid: uid, sid: sid} do
    stub_model(summary: "Bobby likes tea; we discussed Phoenix.", facts: "NONE")

    Memory.persist_turn(%{user_id: uid, user_text: "i like tea", brain_text: "noted"})
    assert :ok = Updater.run(sid)
    assert Memory.get_summary(uid).content =~ "Bobby likes tea"
  end

  test "run/1 keeps the existing summary on model failure", %{uid: uid, sid: sid} do
    stub(App.TextModelMock, :generate, fn _p, _c, _o -> {:error, :boom} end)

    Memory.put_summary(uid, "existing")
    assert :ok = Updater.run(sid)
    assert Memory.get_summary(uid).content == "existing"
  end

  test "run/1 extracts new auto-facts, deduped against what's known", %{uid: uid, sid: sid} do
    {:ok, _} = Memory.create_fact(%{content: "likes tea", source: "user", user_id: uid})

    stub_model(
      summary: "summary",
      facts: "- likes tea\n- building a Phoenix app\n- lives in St. Louis"
    )

    assert :ok = Updater.run(sid)

    contents = Memory.list_facts(uid) |> Enum.map(& &1.content)
    # the already-known "likes tea" is not duplicated; the two new ones are added as auto
    assert "building a Phoenix app" in contents
    assert "lives in St. Louis" in contents
    assert Enum.count(contents, &(&1 == "likes tea")) == 1

    autos =
      Memory.list_facts(uid) |> Enum.filter(&(&1.source == "auto")) |> Enum.map(& &1.content)

    assert "building a Phoenix app" in autos
  end

  test "run/1 stores no facts when extraction says NONE", %{uid: uid, sid: sid} do
    stub_model(summary: "summary", facts: "NONE")
    assert :ok = Updater.run(sid)
    assert Memory.list_facts(uid) == []
  end

  test "run/1 is a no-op for a non-integer session id" do
    assert App.Memory.Updater.run("default") == :ok
  end
end
