defmodule App.Dispatch.ForgeTest do
  use ExUnit.Case, async: false

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

  test "open_prs returns bodies" do
    Req.Test.stub(ForgeStub, fn conn ->
      assert conn.request_path == "/api/v1/repos/kalcode/x/pulls"
      assert URI.decode_query(conn.query_string)["state"] == "open"
      Req.Test.json(conn, [%{"body" => "Closes #3"}, %{"body" => nil}])
    end)

    assert {:ok, ["Closes #3", ""]} = Forge.open_prs("kalcode/x")
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

  test "run returns status and conclusion" do
    Req.Test.stub(ForgeStub, fn conn ->
      assert conn.request_path == "/api/v1/repos/kalcode/claude-dispatch/actions/runs/555"
      Req.Test.json(conn, %{"status" => "completed", "conclusion" => "success"})
    end)

    assert {:ok, %{status: "completed", conclusion: "success"}} = Forge.run(555)
  end

  test "401 -> :unauthorized, 404 -> :not_found, 500 -> {:http, 500}" do
    for {s, want} <- [{401, :unauthorized}, {404, :not_found}, {500, {:http, 500}}] do
      Req.Test.stub(ForgeStub, fn conn -> Plug.Conn.send_resp(conn, s, "") end)
      assert {:error, ^want} = Forge.list_repos()
    end
  end

  test "transport errors are tagged, not raised" do
    Req.Test.stub(ForgeStub, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)
    assert {:error, %{reason: :econnrefused}} = Forge.list_repos()
  end

  test ":not_configured when the env is absent" do
    Application.delete_env(:app, :forge)
    assert {:error, :not_configured} = Forge.list_repos()
    assert {:error, :not_configured} = Forge.dispatch("kalcode/x", 1, 1)
    refute App.Config.forge?()
  end
end
