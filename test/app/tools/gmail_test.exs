defmodule App.Tools.GmailTest do
  use App.DataCase, async: false

  alias App.Google.Account
  alias App.Tools.Gmail, as: Tool
  alias App.Users.User

  @gmail_send "https://www.googleapis.com/auth/gmail.send"
  @gmail_ro "https://www.googleapis.com/auth/gmail.readonly"

  setup do
    {:ok, user} =
      %User{} |> User.changeset(%{email: "alice@x.com", name: "Alice"}) |> Repo.insert()

    Process.put(:test_user_id, user.id)
    %{user: user}
  end

  defp account(email, opts \\ []) do
    {:ok, acc} =
      %Account{}
      |> Account.changeset(%{
        user_id: Process.get(:test_user_id),
        email: email,
        label: Keyword.get(opts, :label, email),
        refresh_token: "rt",
        access_token: "at",
        access_token_expires_at:
          DateTime.add(DateTime.utc_now(), 3600, :second) |> DateTime.truncate(:second),
        scope: Keyword.get(opts, :scope, "#{@gmail_send} #{@gmail_ro} openid email")
      })
      |> Repo.insert()

    acc
  end

  defp ctx do
    uid = Process.get(:test_user_id)
    %{session_id: to_string(uid), user_id: uid, config: App.Config.default()}
  end

  defp header(name, value), do: %{"name" => name, "value" => value}

  test "search_email with no accounts returns a connect note" do
    assert {:ok, %{messages: [], note: note}} = Tool.execute("search_email", %{}, ctx())
    assert note =~ "no Google accounts connected"
  end

  test "search_email defaults to unread inbox, merges accounts, sorts newest first" do
    account("a@x.com")
    account("b@x.com")

    Application.put_env(:app, :google_req_opts, plug: {Req.Test, SearchStub})
    on_exit(fn -> Application.delete_env(:app, :google_req_opts) end)

    Req.Test.stub(SearchStub, fn conn ->
      case conn.request_path do
        "/gmail/v1/users/me/messages" ->
          send(self(), :listed)
          Req.Test.json(conn, %{"messages" => [%{"id" => "m1"}]})

        "/gmail/v1/users/me/messages/m1" ->
          # unique monotonic internalDate per fetch so the sort-order assertion is meaningful
          Req.Test.json(conn, %{
            "snippet" => "s",
            "internalDate" => "#{System.unique_integer([:positive, :monotonic])}",
            "payload" => %{"headers" => [header("From", "x@x.com"), header("Subject", "Hello")]}
          })
      end
    end)

    assert {:ok, %{messages: messages, errors: [], accounts_read: read}} =
             Tool.execute("search_email", %{}, ctx())

    assert length(messages) == 2
    assert Enum.sort(read) == ["a@x.com", "b@x.com"]
    # handle is "<label>:<id>"
    assert Enum.all?(messages, &String.ends_with?(&1.handle, ":m1"))
    assert Enum.all?(messages, &(&1.subject == "Hello"))
    # internal_date is not leaked to the brain
    refute Enum.any?(messages, &Map.has_key?(&1, :internal_date))
  end

  test "search_email skips accounts without gmail read access" do
    account("reader@x.com")
    account("noaccess@x.com", scope: "openid email")

    Application.put_env(:app, :google_req_opts, plug: {Req.Test, ReadStub})
    on_exit(fn -> Application.delete_env(:app, :google_req_opts) end)

    Req.Test.stub(ReadStub, fn conn ->
      case conn.request_path do
        "/gmail/v1/users/me/messages" ->
          Req.Test.json(conn, %{"messages" => [%{"id" => "m1"}]})

        _ ->
          Req.Test.json(conn, %{
            "snippet" => "s",
            "internalDate" => "1",
            "payload" => %{"headers" => [header("Subject", "S")]}
          })
      end
    end)

    assert {:ok, %{accounts_read: ["reader@x.com"]}} = Tool.execute("search_email", %{}, ctx())
  end

  test "read_email resolves the handle, returns the body, caps a huge body" do
    account("a@x.com")
    big = String.duplicate("x", 5_000)

    Application.put_env(:app, :google_req_opts, plug: {Req.Test, ReadOneStub})
    on_exit(fn -> Application.delete_env(:app, :google_req_opts) end)

    Req.Test.stub(ReadOneStub, fn conn ->
      Req.Test.json(conn, %{
        "internalDate" => "1",
        "payload" => %{
          "mimeType" => "text/plain",
          "headers" => [header("From", "a@x.com"), header("Subject", "Big")],
          "body" => %{"data" => Base.url_encode64(big, padding: false)}
        }
      })
    end)

    assert {:ok, %{message: msg}} =
             Tool.execute("read_email", %{"handle" => "a@x.com:m1"}, ctx())

    assert msg.subject == "Big"
    assert String.length(msg.body) <= 2_010
    assert msg.truncated == true
  end

  test "read_email with an unknown handle account returns a note" do
    account("a@x.com")

    assert {:ok, %{note: note}} =
             Tool.execute("read_email", %{"handle" => "ghost@x.com:m1"}, ctx())

    assert note =~ "no connected Gmail account"
  end

  test "send_email sends from the default account and returns the sent summary" do
    a = account("a@x.com")
    account("b@x.com")
    {:ok, _} = App.Google.Accounts.set_default(a)

    Application.put_env(:app, :google_req_opts, plug: {Req.Test, SendStub})
    on_exit(fn -> Application.delete_env(:app, :google_req_opts) end)

    Req.Test.stub(SendStub, fn conn -> Req.Test.json(conn, %{"id" => "s1"}) end)

    args = %{"to" => "you@y.com", "subject" => "Hi", "body" => "hello"}
    assert {:ok, %{sent: sent}} = Tool.execute("send_email", args, ctx())
    assert sent.to == "you@y.com"
    assert sent.account == "a@x.com"
  end

  test "send_email missing recipient or body returns a note (no send)" do
    account("a@x.com")
    assert {:ok, %{note: n1}} = Tool.execute("send_email", %{"body" => "hi"}, ctx())
    assert n1 =~ "recipient"
    assert {:ok, %{note: n2}} = Tool.execute("send_email", %{"to" => "you@y.com"}, ctx())
    assert n2 =~ "body"
  end

  test "send_email reply routes through the handle's account and threads" do
    account("a@x.com")
    test_pid = self()

    Application.put_env(:app, :google_req_opts, plug: {Req.Test, ReplyStub})
    on_exit(fn -> Application.delete_env(:app, :google_req_opts) end)

    Req.Test.stub(ReplyStub, fn conn ->
      case conn.method do
        "GET" ->
          Req.Test.json(conn, %{
            "threadId" => "t9",
            "payload" => %{
              "headers" => [header("Message-ID", "<o@mail>"), header("Subject", "Q")]
            }
          })

        "POST" ->
          {:ok, raw, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:posted, Jason.decode!(raw)})
          Req.Test.json(conn, %{"id" => "s2", "threadId" => "t9"})
      end
    end)

    args = %{"to" => "you@y.com", "body" => "answer", "reply_to" => "a@x.com:orig1"}
    assert {:ok, %{sent: sent}} = Tool.execute("send_email", args, ctx())
    assert sent.subject == "Re: Q"

    assert_received {:posted, body}
    assert body["threadId"] == "t9"
  end

  test "send_email to a read-only gmail account returns a note" do
    account("ro@x.com", scope: "#{@gmail_ro} openid email")

    args = %{"to" => "you@y.com", "subject" => "Hi", "body" => "b", "account" => "ro@x.com"}
    assert {:ok, %{note: note}} = Tool.execute("send_email", args, ctx())
    assert note =~ "read-only"
  end

  test "account_matches reuse: send_email resolves a named account case-insensitively" do
    a = account("person@x.com", label: "Personal")
    {:ok, _} = App.Google.Accounts.set_default(a)

    Application.put_env(:app, :google_req_opts, plug: {Req.Test, NamedStub})
    on_exit(fn -> Application.delete_env(:app, :google_req_opts) end)
    Req.Test.stub(NamedStub, fn conn -> Req.Test.json(conn, %{"id" => "s1"}) end)

    args = %{"to" => "you@y.com", "subject" => "Hi", "body" => "b", "account" => "personal"}
    assert {:ok, %{sent: sent}} = Tool.execute("send_email", args, ctx())
    assert sent.account == "Personal"
  end
end
