defmodule App.Sources.CalendarTest do
  use App.DataCase, async: false
  alias App.Google.Account
  alias App.Sources.Calendar, as: Src

  setup do
    Application.put_env(:app, :allowed_users, [%{email: "cal@x.com", name: "Cal"}])
    Application.put_env(:app, :google_req_opts, plug: {Req.Test, CalSrcStub})

    on_exit(fn ->
      Application.delete_env(:app, :allowed_users)
      Application.delete_env(:app, :google_req_opts)
    end)

    {:ok, u} = App.Users.upsert_allowed("cal@x.com")

    {:ok, acc} =
      %Account{}
      |> Account.changeset(%{
        user_id: u.id,
        email: "cal@x.com",
        label: "Personal",
        refresh_token: "rt",
        access_token: "at",
        access_token_expires_at:
          DateTime.add(DateTime.utc_now(), 3600, :second) |> DateTime.truncate(:second)
      })
      |> Repo.insert()

    %{acc: acc}
  end

  defp stub_event(fields) do
    Req.Test.stub(CalSrcStub, fn conn ->
      Req.Test.json(conn, %{
        "items" => [
          Map.merge(
            %{
              "id" => "evt1",
              "summary" => "Dentist",
              "location" => "123 Main",
              "description" => "cleaning",
              "htmlLink" => "https://cal/evt1",
              "attendees" => [%{"email" => "doc@x.com"}],
              "start" => %{"dateTime" => "2026-07-20T15:00:00Z"},
              "end" => %{"dateTime" => "2026-07-20T15:30:00Z"}
            },
            fields
          )
        ]
      })
    end)
  end

  test "source metadata", %{} do
    assert Src.source_key() == "calendar"
    assert Src.connector() == :calendar
    assert Src.reconcile_mode() == :full
  end

  test "list_refs returns id + content_hash; to_point builds embed_text + payload + at", %{
    acc: acc
  } do
    stub_event(%{})
    assert {:ok, [ref]} = Src.list_refs(acc)
    assert ref.external_id == "evt1"
    assert is_binary(ref.content_hash)

    assert {:ok, point} = Src.to_point(acc, ref)
    assert point.embed_text =~ "Dentist"
    assert point.embed_text =~ "123 Main"
    assert point.payload.source == "calendar"
    assert point.payload.external_id == "evt1"
    assert point.payload.account_id == acc.id
    assert point.payload.account == "Personal"
    assert point.payload.title == "Dentist"
    assert point.payload.link == "https://cal/evt1"
    assert point.payload.location == "123 Main"
    assert String.slice(point.payload.at, 0, 10) == "2026-07-20"
    assert %DateTime{} = point.at
  end

  test "content_hash changes when a field (location) is edited", %{acc: acc} do
    stub_event(%{})
    {:ok, [a]} = Src.list_refs(acc)
    stub_event(%{"location" => "456 Oak"})
    {:ok, [b]} = Src.list_refs(acc)
    refute a.content_hash == b.content_hash
  end

  test "an event with no id is skipped", %{acc: acc} do
    Req.Test.stub(CalSrcStub, fn conn ->
      Req.Test.json(conn, %{
        "items" => [%{"summary" => "ghost", "start" => %{"date" => "2026-07-20"}}]
      })
    end)

    assert {:ok, []} = Src.list_refs(acc)
  end

  test "a list_events error propagates", %{acc: acc} do
    Req.Test.stub(CalSrcStub, fn conn -> Plug.Conn.send_resp(conn, 503, "nope") end)
    assert {:error, _} = Src.list_refs(acc)
  end
end
