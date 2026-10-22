defmodule App.Dispatch.ForgeTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias App.Dispatch.Forge

  @fixture "test/fixtures/dispatch/boards.json" |> File.read!() |> Jason.decode!()

  setup do
    Application.put_env(:app, :forge, %{
      url: "https://forge.example.test",
      token: "forge-token",
      dispatch_repo: "kalcode/claude-dispatch"
    })

    Application.put_env(:app, :dispatch_req_opts, plug: {Req.Test, ForgeStub})

    on_exit(fn ->
      Application.delete_env(:app, :forge)
      Application.delete_env(:app, :dispatch_req_opts)
    end)
  end

  defp auth(conn), do: Plug.Conn.get_req_header(conn, "authorization")

  test "list_repos hits /user/repos and trims fields" do
    Req.Test.stub(ForgeStub, fn conn ->
      assert conn.request_path == "/api/v1/user/repos"
      assert conn.query_string =~ "limit=50"
      assert auth(conn) == ["token forge-token"]
      Req.Test.json(conn, @fixture["repos"])
    end)

    assert {:ok, repos} = Forge.list_repos()
    pa = Enum.find(repos, &(&1.name == "personal-assistant"))
    assert pa.full_name == "kalcode/personal-assistant"
    assert pa.default_branch == "main"
    assert is_integer(pa.open_issues)
  end

  test "list_issues asks for open issues only and normalizes" do
    Req.Test.stub(ForgeStub, fn conn ->
      assert conn.request_path == "/api/v1/repos/kalcode/unwritten-chronicles/issues"
      q = URI.decode_query(conn.query_string)
      assert q["state"] == "open" and q["type"] == "issues"
      Req.Test.json(conn, @fixture["issues"]["unwritten-chronicles"])
    end)

    assert {:ok, issues} = Forge.list_issues("kalcode/unwritten-chronicles")
    i = Enum.find(issues, &(&1.number == 31))
    assert i.labels == ["bug"]
    assert is_binary(i.body)
  end

  test "has_context? is true on CLAUDE.md, falls back to AGENTS.md, false when neither" do
    Req.Test.stub(ForgeStub, fn conn ->
      assert conn.request_path =~ "/api/v1/repos/kalcode/x/contents/"
      assert URI.decode_query(conn.query_string)["ref"] == "main"

      if String.ends_with?(conn.request_path, "AGENTS.md"),
        do: Req.Test.json(conn, %{"name" => "AGENTS.md"}),
        else: Plug.Conn.send_resp(conn, 404, "")
    end)

    assert {:ok, true} = Forge.has_context?("kalcode/x", "main")

    Req.Test.stub(ForgeStub, fn conn -> Plug.Conn.send_resp(conn, 404, "") end)
    assert {:ok, false} = Forge.has_context?("kalcode/x", "main")
  end

  test "open_prs returns each open PR's body and head branch" do
    Req.Test.stub(ForgeStub, fn conn ->
      assert conn.request_path == "/api/v1/repos/kalcode/x/pulls"
      assert URI.decode_query(conn.query_string)["state"] == "open"

      Req.Test.json(conn, [
        %{"body" => "Closes #3", "head" => %{"ref" => "claude/3-fix"}},
        %{"body" => nil}
      ])
    end)

    assert {:ok, [%{body: "Closes #3", head: "claude/3-fix"}, %{body: "", head: nil}]} =
             Forge.open_prs("kalcode/x")
  end

  test "create_issue and comment POST the right bodies" do
    Req.Test.stub(ForgeStub, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(raw)

      case conn.request_path do
        "/api/v1/repos/kalcode/x/issues" ->
          assert body == %{"title" => "T", "body" => "B", "labels" => [7]}
          conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"number" => 42})

        "/api/v1/repos/kalcode/x/issues/42/comments" ->
          assert body == %{"body" => "hello"}
          conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => 1})
      end
    end)

    assert {:ok, %{number: 42}} = Forge.create_issue("kalcode/x", "T", "B", [7])
    assert {:ok, _} = Forge.comment("kalcode/x", 42, "hello")
  end

  test "dispatch posts the contract body and returns run info" do
    Req.Test.stub(ForgeStub, fn conn ->
      assert conn.method == "POST"

      assert conn.request_path ==
               "/api/v1/repos/kalcode/claude-dispatch/actions/workflows/work-issue.yml/dispatches"

      assert auth(conn) == ["token forge-token"]
      {:ok, raw, conn} = Plug.Conn.read_body(conn)

      assert Jason.decode!(raw) == %{
               "ref" => "main",
               "inputs" => %{"repo" => "kalcode/x", "issue" => "31", "job_id" => "9"},
               "return_run_info" => true
             }

      Req.Test.json(conn, %{"id" => 555, "run_number" => 12, "jobs" => []})
    end)

    assert {:ok, %{run_id: 555, run_number: 12}} = Forge.dispatch("kalcode/x", 31, 9)
  end

  test "dispatch with no run info or a junk body is a tagged error" do
    for {resp, want} <- [{"", :no_run_info}, {"[]", :bad_body}] do
      Req.Test.stub(ForgeStub, fn conn -> Plug.Conn.send_resp(conn, 200, resp) end)
      assert {:error, ^want} = Forge.dispatch("kalcode/x", 1, 1)
    end

    Req.Test.stub(ForgeStub, fn conn -> Plug.Conn.send_resp(conn, 204, "") end)
    assert {:error, :no_run_info} = Forge.dispatch("kalcode/x", 1, 1)
  end

  test "non-list bodies on list endpoints are :bad_body" do
    Req.Test.stub(ForgeStub, fn conn -> Req.Test.json(conn, %{"message" => "hm"}) end)
    assert {:error, :bad_body} = Forge.list_issues("kalcode/x")
    assert {:error, :bad_body} = Forge.list_repos()
    assert {:error, :bad_body} = Forge.open_prs("kalcode/x")
  end

  test "run returns Forgejo's status and stopped time" do
    Req.Test.stub(ForgeStub, fn conn ->
      assert conn.request_path == "/api/v1/repos/kalcode/claude-dispatch/actions/runs/555"

      Req.Test.json(conn, %{
        "id" => 555,
        "status" => "success",
        "conclusion" => nil,
        "stopped" => "2026-10-21T12:00:00Z",
        "index_in_repo" => 3,
        "html_url" => "https://forge.example.test/x"
      })
    end)

    assert {:ok, %{status: "success", stopped: ~U[2026-10-21 12:00:00Z]}} = Forge.run(555)
  end

  test "run treats a zero or epoch stopped stamp as not stopped" do
    for stamp <- ["0001-01-01T00:00:00Z", "1970-01-01T00:00:00Z", "1999-12-31T23:59:59Z"] do
      Req.Test.stub(ForgeStub, fn conn ->
        Req.Test.json(conn, %{"status" => "running", "stopped" => stamp})
      end)

      assert {:ok, %{status: "running", stopped: nil}} = Forge.run(555), stamp
    end
  end

  test "issue returns one issue with its state" do
    Req.Test.stub(ForgeStub, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/api/v1/repos/kalcode/x/issues/31"

      Req.Test.json(conn, %{
        "number" => 31,
        "title" => "T",
        "state" => "closed",
        "labels" => [%{"name" => "bug"}],
        "body" => "B",
        "pull_request" => nil,
        "html_url" => "https://forge.example.test/kalcode/x/issues/31"
      })
    end)

    assert {:ok, %{number: 31, state: "closed", pull_request: false, labels: ["bug"]}} =
             Forge.issue("kalcode/x", 31)

    Req.Test.stub(ForgeStub, fn conn -> Plug.Conn.send_resp(conn, 404, "") end)
    assert {:error, :not_found} = Forge.issue("kalcode/x", 999)
  end

  test "labels lists the repo's label ids and names" do
    Req.Test.stub(ForgeStub, fn conn ->
      assert conn.request_path == "/api/v1/repos/kalcode/x/labels"
      Req.Test.json(conn, [%{"id" => 10, "name" => "bug"}, %{"id" => 11, "name" => "Feature"}])
    end)

    assert {:ok, [%{id: 10, name: "bug"}, %{id: 11, name: "Feature"}]} = Forge.labels("kalcode/x")

    Req.Test.stub(ForgeStub, fn conn -> Req.Test.json(conn, %{"message" => "hm"}) end)
    assert {:error, :bad_body} = Forge.labels("kalcode/x")
  end

  test "file reads a file's raw text at a ref, not_found when absent" do
    Req.Test.stub(ForgeStub, fn conn ->
      assert conn.request_path == "/api/v1/repos/kalcode/x/raw/CLAUDE.md"
      assert URI.decode_query(conn.query_string)["ref"] == "main"
      assert auth(conn) == ["token forge-token"]

      conn
      |> Plug.Conn.put_resp_content_type("text/plain")
      |> Plug.Conn.send_resp(200, "# Guide\n\nbrainstorming (HARD GATE)")
    end)

    assert {:ok, "# Guide\n\nbrainstorming (HARD GATE)"} =
             Forge.file("kalcode/x", "CLAUDE.md", "main")

    Req.Test.stub(ForgeStub, fn conn -> Plug.Conn.send_resp(conn, 404, "") end)
    assert {:error, :not_found} = Forge.file("kalcode/x", "AGENTS.md", "main")
  end

  test "401 -> :unauthorized, 404 -> :not_found, 500 -> {:http, 500}" do
    for {s, want} <- [{401, :unauthorized}, {404, :not_found}, {500, {:http, 500}}] do
      Req.Test.stub(ForgeStub, fn conn -> Plug.Conn.send_resp(conn, s, "") end)
      assert {:error, ^want} = Forge.list_repos()
    end
  end

  test "transport errors are tagged, not raised (after the never-executed retries)" do
    # A STUBBED refusal, not a real connection: App.Http.Retry retries it (it never reached the
    # server) and logs each retry, which this captures so the suite output stays clean.
    Req.Test.stub(ForgeStub, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

    log =
      capture_log(fn ->
        assert {:error, %{reason: :econnrefused}} = Forge.list_repos()
      end)

    assert log =~ "[http] retrying transient :econnrefused"
  end

  test ":not_configured when the env is absent" do
    Application.delete_env(:app, :forge)
    assert {:error, :not_configured} = Forge.list_repos()
    assert {:error, :not_configured} = Forge.dispatch("kalcode/x", 1, 1)
    refute App.Config.forge?()
  end
end
