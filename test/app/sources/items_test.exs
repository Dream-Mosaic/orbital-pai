defmodule App.Sources.ItemsTest do
  use App.DataCase, async: false
  alias App.Sources.Items

  setup do
    Application.put_env(:app, :allowed_users, [%{email: "it@x.com", name: "It"}])
    on_exit(fn -> Application.delete_env(:app, :allowed_users) end)
    {:ok, u} = App.Users.upsert_allowed("it@x.com")
    %{uid: u.id}
  end

  defp rec(uid, source, acct, ext, hash, at \\ nil) do
    {:ok, _} =
      Items.record(%{
        user_id: uid,
        account_id: acct,
        source: source,
        external_id: ext,
        content_hash: hash,
        at: at,
        indexed_at: DateTime.utc_now()
      })
  end

  test "record is an upsert; refs_indexed returns external_id => content_hash", %{uid: uid} do
    rec(uid, "email", 1, "m1", "h1")
    rec(uid, "email", 1, "m1", "h2")
    assert Items.refs_indexed(uid, "email", 1) == %{"m1" => "h2"}
  end

  test "refs_indexed is scoped by user, source, and account", %{uid: uid} do
    rec(uid, "email", 1, "m1", "h1")
    rec(uid, "calendar", 1, "e1", "hc")
    rec(uid, "email", 2, "m2", "h2")
    assert Items.refs_indexed(uid, "email", 1) == %{"m1" => "h1"}
  end

  test "delete_missing drops rows whose external_id is not live, returns them", %{uid: uid} do
    rec(uid, "calendar", 1, "e1", "h")
    rec(uid, "calendar", 1, "e2", "h")
    dropped = Items.delete_missing(uid, "calendar", 1, MapSet.new(["e1"]))
    assert dropped == ["e2"]
    assert Items.refs_indexed(uid, "calendar", 1) == %{"e1" => "h"}
  end

  test "prune_older_than drops rows older than the cutoff, returns them", %{uid: uid} do
    old = ~U[2020-01-01 00:00:00Z]
    new = ~U[2030-01-01 00:00:00Z]
    rec(uid, "email", 1, "old", "h", old)
    rec(uid, "email", 1, "new", "h", new)
    dropped = Items.prune_older_than(uid, "email", 1, ~U[2025-01-01 00:00:00Z])
    assert dropped == ["old"]
    assert Map.keys(Items.refs_indexed(uid, "email", 1)) == ["new"]
  end

  test "delete_for_account clears one account; delete_for_user clears all", %{uid: uid} do
    rec(uid, "email", 1, "m1", "h")
    rec(uid, "email", 2, "m2", "h")
    :ok = Items.delete_for_account(uid, 1)
    assert Items.refs_indexed(uid, "email", 1) == %{}
    assert Items.refs_indexed(uid, "email", 2) == %{"m2" => "h"}
    :ok = Items.delete_for_user(uid)
    assert Items.refs_indexed(uid, "email", 2) == %{}
  end
end
