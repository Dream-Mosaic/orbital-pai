defmodule App.Google.GmailTest do
  use App.DataCase, async: false

  alias App.Google.{Account, Gmail}
  alias App.Users.User

  defp account do
    {:ok, acc} =
      %Account{}
      |> Account.changeset(%{
        user_id: Process.get(:test_user_id),
        email: "me@x.com",
        label: "me@x.com",
        refresh_token: "rt",
        access_token: "at",
        access_token_expires_at:
          DateTime.add(DateTime.utc_now(), 3600, :second) |> DateTime.truncate(:second)
      })
      |> Repo.insert()

    acc
  end

  defp b64(s), do: Base.url_encode64(s, padding: false)

  setup do
    {:ok, user} =
      %User{} |> User.changeset(%{email: "alice@x.com", name: "Alice"}) |> Repo.insert()

    Process.put(:test_user_id, user.id)
    Application.put_env(:app, :google_req_opts, plug: {Req.Test, GmailStub})
    on_exit(fn -> Application.delete_env(:app, :google_req_opts) end)
    :ok
  end

  defp header(name, value), do: %{"name" => name, "value" => value}

  test "list_messages lists ids then fetches metadata per message" do
    Req.Test.stub(GmailStub, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/gmail/v1/users/me/messages"} ->
          Req.Test.json(conn, %{"messages" => [%{"id" => "m1"}, %{"id" => "m2"}]})

        {"GET", "/gmail/v1/users/me/messages/m1"} ->
          Req.Test.json(conn, %{
            "snippet" => "snippet one",
            "internalDate" => "1000",
            "payload" => %{
              "headers" => [
                header("From", "Alice <a@x.com>"),
                header("Subject", "One"),
                header("Date", "Mon")
              ]
            }
          })

        {"GET", "/gmail/v1/users/me/messages/m2"} ->
          Req.Test.json(conn, %{
            "snippet" => "snippet two",
            "internalDate" => "2000",
            "payload" => %{
              "headers" => [
                header("From", "Bob <b@x.com>"),
                header("Subject", "Two"),
                header("Date", "Tue")
              ]
            }
          })
      end
    end)

    assert {:ok, messages} = Gmail.list_messages(account(), q: "is:unread in:inbox")
    assert length(messages) == 2

    m1 = Enum.find(messages, &(&1.id == "m1"))
    assert m1.from == "Alice <a@x.com>"
    assert m1.subject == "One"
    assert m1.snippet == "snippet one"
    assert m1.internal_date == "1000"
  end

  test "list_messages returns [] when the inbox query has no messages key" do
    Req.Test.stub(GmailStub, fn conn -> Req.Test.json(conn, %{"resultSizeEstimate" => 0}) end)
    assert {:ok, []} = Gmail.list_messages(account(), q: "is:unread")
  end

  test "list_messages surfaces an API error on the list call" do
    Req.Test.stub(GmailStub, fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end)
    assert {:error, {:http, 500}} = Gmail.list_messages(account(), q: "x")
  end

  test "get_message returns the parsed plaintext body and headers" do
    Req.Test.stub(GmailStub, fn conn ->
      Req.Test.json(conn, %{
        "internalDate" => "1000",
        "payload" => %{
          "mimeType" => "text/plain",
          "headers" => [
            header("From", "Alice <a@x.com>"),
            header("Subject", "Hello"),
            header("Date", "Mon")
          ],
          "body" => %{"data" => b64("the full body")}
        }
      })
    end)

    assert {:ok, msg} = Gmail.get_message(account(), "m1")
    assert msg.from == "Alice <a@x.com>"
    assert msg.subject == "Hello"
    assert msg.body == "the full body"
  end

  test "send_message posts a base64url raw message and returns the sent summary" do
    test_pid = self()

    Req.Test.stub(GmailStub, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:posted, Jason.decode!(raw)})
      Req.Test.json(conn, %{"id" => "sent1", "threadId" => "t1"})
    end)

    assert {:ok, sent} =
             Gmail.send_message(account(), %{to: "you@y.com", subject: "Hi", body: "hello"})

    assert sent.to == "you@y.com"
    assert sent.subject == "Hi"
    assert sent.account == "me@x.com"

    assert_received {:posted, body}
    decoded = Base.url_decode64!(body["raw"], padding: false)
    assert decoded =~ "To: you@y.com"
    assert decoded =~ "Subject: Hi"
    refute Map.has_key?(body, "threadId")
  end

  test "a reply fetches the original metadata then sends with threading headers + threadId" do
    test_pid = self()

    Req.Test.stub(GmailStub, fn conn ->
      case conn.method do
        "GET" ->
          Req.Test.json(conn, %{
            "threadId" => "thread9",
            "payload" => %{
              "headers" => [
                header("Message-ID", "<orig@mail>"),
                header("Subject", "Question"),
                header("References", "<root@mail>")
              ]
            }
          })

        "POST" ->
          {:ok, raw, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:posted, Jason.decode!(raw)})
          Req.Test.json(conn, %{"id" => "sent2", "threadId" => "thread9"})
      end
    end)

    assert {:ok, sent} =
             Gmail.send_message(account(), %{
               to: "you@y.com",
               subject: nil,
               body: "the answer",
               reply_to_id: "orig1"
             })

    assert sent.subject == "Re: Question"

    assert_received {:posted, body}
    assert body["threadId"] == "thread9"
    decoded = Base.url_decode64!(body["raw"], padding: false)
    assert decoded =~ "In-Reply-To: <orig@mail>"
    assert decoded =~ "References: <root@mail> <orig@mail>"
    assert decoded =~ "Subject: Re: Question"
  end

  test "send_message maps a 403 to needs_write_access" do
    Req.Test.stub(GmailStub, fn conn -> Plug.Conn.send_resp(conn, 403, "no") end)

    assert {:error, :needs_write_access} =
             Gmail.send_message(account(), %{to: "you@y.com", subject: "Hi", body: "b"})
  end
end
