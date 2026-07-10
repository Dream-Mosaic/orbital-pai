defmodule App.Sources.GmailTest do
  use App.DataCase, async: false
  alias App.Google.Account
  alias App.Sources.Gmail, as: Src

  setup do
    Application.put_env(:app, :allowed_users, [%{email: "gm@x.com", name: "Gm"}])
    Application.put_env(:app, :google_req_opts, plug: {Req.Test, GmSrcStub})

    on_exit(fn ->
      Application.delete_env(:app, :allowed_users)
      Application.delete_env(:app, :google_req_opts)
    end)

    {:ok, u} = App.Users.upsert_allowed("gm@x.com")

    {:ok, acc} =
      %Account{}
      |> Account.changeset(%{
        user_id: u.id,
        email: "gm@x.com",
        label: "Work",
        refresh_token: "rt",
        access_token: "at",
        access_token_expires_at:
          DateTime.add(DateTime.utc_now(), 3600, :second) |> DateTime.truncate(:second)
      })
      |> Repo.insert()

    %{acc: acc}
  end

  # A tiny multipart/plain message body for messages.get?format=full.
  defp full_message(id, body_text) do
    %{
      "id" => id,
      "internalDate" => "1783000000000",
      "payload" => %{
        "headers" => [
          %{"name" => "From", "value" => "boss@x.com"},
          %{"name" => "Subject", "value" => "Q3 plan"},
          %{"name" => "Date", "value" => "Mon, 20 Jul 2026 10:00:00 +0000"}
        ],
        "mimeType" => "text/plain",
        "body" => %{"data" => Base.url_encode64(body_text, padding: false)}
      }
    }
  end

  test "source metadata" do
    assert Src.source_key() == "email"
    assert Src.connector() == :gmail
    assert Src.reconcile_mode() == :age_out
  end

  test "list_refs returns ids; content_hash == external_id (email is immutable)", %{acc: acc} do
    Req.Test.stub(GmSrcStub, fn conn ->
      Req.Test.json(conn, %{"messages" => [%{"id" => "m1"}, %{"id" => "m2"}]})
    end)

    assert {:ok, refs} = Src.list_refs(acc)
    assert Enum.map(refs, & &1.external_id) == ["m1", "m2"]
    assert Enum.all?(refs, &(&1.content_hash == &1.external_id))
  end

  test "to_point fetches the body, builds embed_text + payload + at", %{acc: acc} do
    Req.Test.stub(GmSrcStub, fn conn ->
      Req.Test.json(conn, full_message("m1", "let's ship in Q3"))
    end)

    ref = %{external_id: "m1", content_hash: "m1", raw: "m1"}
    assert {:ok, point} = Src.to_point(acc, ref)
    assert point.embed_text =~ "Subject: Q3 plan"
    assert point.embed_text =~ "let's ship in Q3"
    assert point.payload.source == "email"
    assert point.payload.external_id == "m1"
    assert point.payload.account_id == acc.id
    assert point.payload.subject == "Q3 plan"
    assert point.payload.from == "boss@x.com"
    assert point.payload.snippet =~ "ship"
    assert point.payload.link =~ "m1"
    assert %DateTime{} = point.at
  end

  test "to_point truncates a very long body in the embed_text", %{acc: acc} do
    huge = String.duplicate("x", 40_000)

    Req.Test.stub(GmSrcStub, fn conn ->
      Req.Test.json(conn, full_message("m1", huge))
    end)

    {:ok, point} = Src.to_point(acc, %{external_id: "m1", content_hash: "m1", raw: "m1"})
    assert byte_size(point.embed_text) < 30_000
  end
end
