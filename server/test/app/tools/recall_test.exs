defmodule App.Tools.RecallTest do
  use App.DataCase, async: false
  alias App.Users

  setup do
    Application.put_env(:app, :allowed_users, [%{email: "d@x.com", name: "Alice"}])
    on_exit(fn -> Application.delete_env(:app, :allowed_users) end)
    {:ok, u} = Users.upsert_allowed("d@x.com")
    %{user: u}
  end

  test "declaration + execute round-trip", %{user: user} do
    [decl] = App.Tools.Recall.declarations()
    assert decl.name == "recall_memory"

    {:ok, _} =
      App.Memory.persist_turn(%{
        user_id: user.id,
        user_text: "the drone crashed",
        brain_text: "oh no"
      })

    assert {:ok, %{matches: [m]}} =
             App.Tools.Recall.execute("recall_memory", %{"query" => "drone"}, %{user_id: user.id})

    assert m.you =~ "drone"

    assert {:ok, %{matches: []}} =
             App.Tools.Recall.execute("recall_memory", %{"query" => "drone"}, %{user_id: nil})
  end
end
