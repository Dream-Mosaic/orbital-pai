defmodule App.Sources.IngesterTest do
  use App.DataCase, async: false
  alias App.Google.Account
  alias App.Sources.{Ingester, Items}
  alias App.Test.Fakes.VectorStore

  setup do
    VectorStore.reset()
    Application.put_env(:app, :allowed_users, [%{email: "ing@x.com", name: "Ing"}])
    Application.put_env(:app, :source_modules, [App.Test.Fakes.Source])

    on_exit(fn ->
      Application.delete_env(:app, :allowed_users)
      Application.delete_env(:app, :source_modules)
      Application.delete_env(:app, :fake_source_refs)
      Application.delete_env(:app, :fake_source_mode)
    end)

    {:ok, u} = App.Users.upsert_allowed("ing@x.com")

    {:ok, acc} =
      %Account{}
      |> Account.changeset(%{
        user_id: u.id,
        email: "ing@x.com",
        label: "Acct",
        refresh_token: "rt",
        access_token: "at",
        access_token_expires_at:
          DateTime.add(DateTime.utc_now(), 3600, :second) |> DateTime.truncate(:second),
        scope: "https://www.googleapis.com/auth/gmail.readonly"
      })
      |> Repo.insert()

    %{uid: u.id, acc: acc}
  end

  test "new refs embed, upsert, and record source_items", %{uid: uid, acc: acc} do
    Application.put_env(:app, :fake_source_refs, [
      %{external_id: "m1", content_hash: "m1", at: ~U[2026-07-01 00:00:00Z]},
      %{external_id: "m2", content_hash: "m2", at: ~U[2026-07-01 00:00:00Z]}
    ])

    assert :ok = Ingester.run_user(uid)
    assert Items.refs_indexed(uid, "email", acc.id) == %{"m1" => "m1", "m2" => "m2"}
    {:ok, hits} = VectorStore.search([0.0], uid, 10)
    assert length(hits) == 2
  end

  test "is idempotent — a second run with the same refs indexes nothing new", %{uid: uid} do
    Application.put_env(:app, :fake_source_refs, [
      %{external_id: "m1", content_hash: "m1", at: ~U[2026-07-01 00:00:00Z]}
    ])

    :ok = Ingester.run_user(uid)
    {:ok, before} = VectorStore.search([0.0], uid, 10)
    :ok = Ingester.run_user(uid)
    {:ok, after_} = VectorStore.search([0.0], uid, 10)
    assert length(before) == length(after_)
  end

  test "a changed content_hash re-embeds (record reflects the new hash)", %{uid: uid, acc: acc} do
    Application.put_env(:app, :fake_source_refs, [
      %{external_id: "m1", content_hash: "h1", at: ~U[2026-07-01 00:00:00Z]}
    ])

    :ok = Ingester.run_user(uid)

    Application.put_env(:app, :fake_source_refs, [
      %{external_id: "m1", content_hash: "h2", at: ~U[2026-07-01 00:00:00Z]}
    ])

    :ok = Ingester.run_user(uid)
    assert Items.refs_indexed(uid, "email", acc.id) == %{"m1" => "h2"}
  end

  test "per-tick cap bounds new indexes", %{uid: uid} do
    Application.put_env(:app, :source_ingest_batch_override, 1)
    on_exit(fn -> Application.delete_env(:app, :source_ingest_batch_override) end)

    Application.put_env(:app, :fake_source_refs, [
      %{external_id: "m1", content_hash: "m1", at: ~U[2026-07-01 00:00:00Z]},
      %{external_id: "m2", content_hash: "m2", at: ~U[2026-07-01 00:00:00Z]}
    ])

    :ok = Ingester.run_user(uid)
    {:ok, hits} = VectorStore.search([0.0], uid, 10)
    assert length(hits) == 1
  end

  test "source_items is NOT recorded when the upsert fails", %{uid: uid, acc: acc} do
    Application.put_env(:app, :fake_source_refs, [
      %{external_id: "m1", content_hash: "m1", at: ~U[2026-07-01 00:00:00Z]}
    ])

    Application.put_env(:app, :fake_vector_error, true)
    on_exit(fn -> Application.delete_env(:app, :fake_vector_error) end)

    assert :ok = Ingester.run_user(uid)
    assert Items.refs_indexed(uid, "email", acc.id) == %{}
  end

  test "a list_refs failure prunes nothing and doesn't crash", %{uid: uid, acc: acc} do
    Application.put_env(:app, :fake_source_refs, [
      %{external_id: "m1", content_hash: "m1", at: ~U[2026-07-01 00:00:00Z]}
    ])

    :ok = Ingester.run_user(uid)
    Application.put_env(:app, :fake_source_refs, {:error, :boom})
    assert :ok = Ingester.run_user(uid)
    assert Items.refs_indexed(uid, "email", acc.id) == %{"m1" => "m1"}
  end

  test "full reconcile drops a vanished item's row + vector", %{uid: uid, acc: acc} do
    Application.put_env(:app, :fake_source_mode, :full)

    Application.put_env(:app, :fake_source_refs, [
      %{external_id: "m1", content_hash: "m1", at: ~U[2026-07-01 00:00:00Z]},
      %{external_id: "m2", content_hash: "m2", at: ~U[2026-07-01 00:00:00Z]}
    ])

    :ok = Ingester.run_user(uid)

    Application.put_env(:app, :fake_source_refs, [
      %{external_id: "m1", content_hash: "m1", at: ~U[2026-07-01 00:00:00Z]}
    ])

    :ok = Ingester.run_user(uid)

    assert Map.keys(Items.refs_indexed(uid, "email", acc.id)) == ["m1"]
    {:ok, hits} = VectorStore.search([0.0], uid, 10)
    assert Enum.map(hits, & &1.id) == ["#{acc.id}:m1"]
  end
end
