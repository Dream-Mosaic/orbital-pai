defmodule App.Tools.ClaudeDispatchTest do
  use App.DataCase, async: false

  import ExUnit.CaptureLog

  alias App.{Dispatch, Users}
  alias App.Dispatch.Board
  alias App.Tools.ClaudeDispatch, as: Tool

  @fixture "test/fixtures/dispatch/boards.json" |> File.read!() |> Jason.decode!()
  @dispatch_path "/repos/kalcode/claude-dispatch/actions/workflows/work-issue.yml/dispatches"
  @gated_claude_md "# CLAUDE.md\n\n1. **brainstorming** (HARD GATE) — every feature starts here."

  setup do
    Application.put_env(:app, :allowed_users, [
      %{email: "david@x.com", name: "David Clausen"},
      %{email: "tanya@x.com", name: "Tanya"}
    ])

    Application.put_env(:app, :claude_dispatch_users, ["david@x.com"])

    Application.put_env(:app, :forge, %{
      url: "https://forge.test",
      token: "t",
      dispatch_repo: "kalcode/claude-dispatch"
    })

    Application.put_env(:app, :dispatch_req_opts, plug: {Req.Test, ForgeStub})
    Board.forget()

    on_exit(fn ->
      for k <- [:allowed_users, :claude_dispatch_users, :forge, :dispatch_req_opts],
          do: Application.delete_env(:app, k)

      Board.forget()
    end)

    {:ok, david} = Users.upsert_allowed("david@x.com")
    {:ok, tanya} = Users.upsert_allowed("tanya@x.com")
    %{david: david, tanya: tanya}
  end

  defp ctx(user),
    do: %{session_id: to_string(user.id), user_id: user.id, config: App.Config.default()}

  # A fake forge built on the B1 fixture. Every request is reported to the test as
  # {:forge, method, path, decoded_body}; `overrides` maps {method, path} (path without /api/v1)
  # to a fun(conn) for the cases a test changes.
  defp forge(overrides \\ %{}) do
    test = self()

    Req.Test.stub(ForgeStub, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = if raw == "", do: nil, else: Jason.decode!(raw)
      path = String.replace_prefix(conn.request_path, "/api/v1", "")
      send(test, {:forge, conn.method, path, body})

      case Map.get(overrides, {conn.method, path}) do
        nil -> route(conn, conn.method, String.split(path, "/", trim: true), body)
        fun -> fun.(conn)
      end
    end)
  end

  defp route(conn, "GET", ["user", "repos"], _), do: Req.Test.json(conn, @fixture["repos"])

  defp route(conn, "GET", ["repos", "kalcode", name, "issues"], _),
    do: Req.Test.json(conn, @fixture["issues"][name] || [])

  defp route(conn, "GET", ["repos", "kalcode", name, "issues", n], _) do
    case Enum.find(@fixture["issues"][name] || [], &(to_string(&1["number"]) == n)) do
      nil -> Plug.Conn.send_resp(conn, 404, ~s({"message":"not found"}))
      issue -> Req.Test.json(conn, Map.put(issue, "state", "open"))
    end
  end

  defp route(conn, "GET", ["repos", "kalcode", _, "pulls"], _), do: Req.Test.json(conn, [])

  defp route(conn, "GET", ["repos", "kalcode", "personal-assistant", "raw", "CLAUDE.md"], _),
    do: Plug.Conn.send_resp(conn, 200, @gated_claude_md)

  defp route(conn, "GET", ["repos", "kalcode", "unwritten-chronicles", "raw", "CLAUDE.md"], _),
    do: Plug.Conn.send_resp(conn, 200, "# Unwritten Chronicles\n\nRun npm test before a PR.")

  defp route(conn, "GET", ["repos", "kalcode", _, "raw", _], _),
    do: Plug.Conn.send_resp(conn, 404, "")

  defp route(conn, "GET", ["repos", "kalcode", _, "labels"], _) do
    Req.Test.json(conn, [
      %{"id" => 10, "name" => "bug"},
      %{"id" => 11, "name" => "Feature"},
      %{"id" => 12, "name" => "debt"}
    ])
  end

  defp route(conn, "POST", ["repos", "kalcode", _, "issues", _, "comments"], _),
    do: conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => 1})

  defp route(conn, "POST", ["repos", "kalcode", name, "issues"], _) do
    conn
    |> Plug.Conn.put_status(201)
    |> Req.Test.json(%{
      "number" => 99,
      "html_url" => "https://forge.test/kalcode/#{name}/issues/99"
    })
  end

  defp route(conn, "POST", ["repos", "kalcode", "claude-dispatch" | _], body) do
    n = String.to_integer(body["inputs"]["issue"])
    Req.Test.json(conn, %{"id" => 500 + n, "run_number" => n, "jobs" => []})
  end

  defp forge_calls do
    receive do
      {:forge, method, path, body} -> [{method, path, body} | forge_calls()]
    after
      0 -> []
    end
  end

  defp nums(rows), do: Enum.map(rows, & &1.number)

  test "declares the four tools, bridges two, and marks the reads read-only" do
    assert Enum.map(Tool.declarations(), & &1.name) ==
             ~w(code_board start_claude claude_jobs file_issue)

    assert Tool.bridge("code_board") == ["Checking the board."]
    assert Tool.bridge("start_claude") == ["Starting Claude."]
    assert Tool.bridge("claude_jobs") == []
    assert Tool.bridge("file_issue") == []

    assert App.Tools.read_only?("code_board")
    assert App.Tools.read_only?("claude_jobs")
    refute App.Tools.read_only?("start_claude")
    refute App.Tools.read_only?("file_issue")
  end

  describe "the per-user gate" do
    test "David can read the board", %{david: d} do
      forge()

      assert {:ok, %{repo: "unwritten-chronicles", issues: [first | _]}} =
               Tool.execute("code_board", %{"repo" => "the chronicles app"}, ctx(d))

      assert %{number: 31, verdict: "candidate (bug)"} = first
    end

    test "anyone else is refused before any forge call", %{tanya: t} do
      forge()

      calls = [
        {"code_board", %{}},
        {"code_board", %{"repo" => "chronicles"}},
        {"start_claude", %{"repo" => "chronicles", "issues" => [31]}},
        {"claude_jobs", %{}},
        {"file_issue", %{"repo" => "chronicles", "title" => "T", "body" => "B"}}
      ]

      for {name, args} <- calls do
        assert {:ok, %{error: "that's not set up for you"}} == Tool.execute(name, args, ctx(t))
      end

      assert forge_calls() == []
      assert Dispatch.list_jobs(t.id) == []
    end

    test "no signed-in user is refused too", %{david: d} do
      forge()
      no_user = %{ctx(d) | user_id: nil}

      assert {:ok, %{error: "that's not set up for you"}} =
               Tool.execute("code_board", %{}, no_user)

      assert forge_calls() == []
    end

    test "an unconfigured forge says so", %{david: d} do
      Application.delete_env(:app, :forge)

      assert {:ok, %{error: "the forge isn't configured on this server"}} =
               Tool.execute("code_board", %{}, ctx(d))
    end
  end

  describe "code_board" do
    test "no repo: the repos with open issues, most candidates first", %{david: d} do
      forge()
      assert {:ok, %{repos: repos}} = Tool.execute("code_board", %{}, ctx(d))

      assert [
               %{repo: "personal-assistant", open: 15, candidates: 12, has_context: true},
               %{repo: "unwritten-chronicles", open: 23, candidates: 6, has_context: true},
               %{repo: "doughty-lab", open: 0, candidates: 0, has_context: false}
             ] = repos
    end

    test "a repo: triaged issues, candidates first, capped at 20", %{david: d} do
      forge()

      assert {:ok, board} =
               Tool.execute("code_board", %{"repo" => "unwritten chronicles"}, ctx(d))

      assert %{repo: "unwritten-chronicles", open: 23, candidates: 6, has_context: true} = board
      assert board.design_gated == false
      assert length(board.issues) == 20
      assert board.more == 3
      assert board.jobs == []

      {cands, skips} = Enum.split(board.issues, 6)
      assert nums(cands) == [31, 30, 15, 16, 2, 1]

      assert Enum.map(cands, & &1.verdict) ==
               List.duplicate("candidate (bug)", 3) ++
                 List.duplicate("candidate (feature)", 3)

      assert Enum.all?(skips, &(&1.verdict == "skip (idea)"))
      assert nums(skips) == Enum.sort(nums(skips), :desc)

      thirty_one = hd(cands)
      assert thirty_one.title =~ "Truncated Action"
      assert thirty_one.labels == ["bug"]
      assert is_binary(thirty_one.gist) and thirty_one.gist != ""
      refute thirty_one.gist =~ "\n"
      assert String.length(thirty_one.gist) <= 121
    end

    test "a design-gated repo turns feature work into design PRs", %{david: d} do
      forge()

      assert {:ok, board} = Tool.execute("code_board", %{"repo" => "Henry"}, ctx(d))
      assert %{repo: "personal-assistant", design_gated: true, has_context: true} = board

      by_num = Map.new(board.issues, &{&1.number, &1.verdict})
      assert by_num[17] == "candidate (design PR)"
      assert by_num[23] == "candidate (bug)"
      assert by_num[24] == "candidate (debt)"
      assert by_num[25] == "skip (idea)"

      assert {"GET", "/repos/kalcode/personal-assistant/raw/CLAUDE.md", nil} in forge_calls()
    end

    test "a repo with no CLAUDE.md or AGENTS.md says so", %{david: d} do
      forge(%{
        {"GET", "/repos/kalcode/unwritten-chronicles/raw/CLAUDE.md"} =>
          &Plug.Conn.send_resp(&1, 404, "")
      })

      assert {:ok, %{has_context: false, design_gated: false}} =
               Tool.execute("code_board", %{"repo" => "chronicles"}, ctx(d))
    end

    test "an open PR that closes an issue, and an active job, skip it", %{david: d} do
      forge(%{
        {"GET", "/repos/kalcode/unwritten-chronicles/pulls"} =>
          &Req.Test.json(&1, [%{"body" => "Fixes the filter.\n\nCloses #31"}])
      })

      {:ok, job} = Dispatch.create_job(d.id, "kalcode/unwritten-chronicles", 30)

      assert {:ok, board} = Tool.execute("code_board", %{"repo" => "chronicles"}, ctx(d))
      by_num = Map.new(board.issues, &{&1.number, &1.verdict})
      assert by_num[31] == "skip (PR already open)"
      assert by_num[30] == "skip (job already active)"
      assert by_num[15] == "candidate (bug)"
      assert [%{issue: 30, status: "queued", job_id: id}] = board.jobs
      assert id == job.id
    end

    test "an ambiguous repo name asks", %{david: d} do
      forge(%{
        {"GET", "/user/repos"} =>
          &Req.Test.json(&1, [
            %{"name" => "garden-planner", "full_name" => "kalcode/garden-planner"},
            %{"name" => "garden-journal", "full_name" => "kalcode/garden-journal"}
          ])
      })

      assert {:ok, %{ask: names}} = Tool.execute("code_board", %{"repo" => "garden"}, ctx(d))
      assert Enum.sort(names) == ["garden-journal", "garden-planner"]
    end

    test "an unknown repo name lists what there is", %{david: d} do
      forge()

      assert {:ok, %{note: note, repos: names}} =
               Tool.execute("code_board", %{"repo" => "zzz"}, ctx(d))

      assert note =~ "zzz"
      assert "unwritten-chronicles" in names
    end

    test "the repo list and context files are cached between reads", %{david: d} do
      forge()
      assert {:ok, _} = Tool.execute("code_board", %{"repo" => "chronicles"}, ctx(d))
      assert {:ok, _} = Tool.execute("code_board", %{"repo" => "chronicles"}, ctx(d))

      paths = Enum.map(forge_calls(), &elem(&1, 1))
      assert Enum.count(paths, &(&1 == "/user/repos")) == 1
      assert Enum.count(paths, &(&1 == "/repos/kalcode/unwritten-chronicles/raw/CLAUDE.md")) == 1
      # Issues are never cached: a new issue or PR shows at once.
      assert Enum.count(paths, &(&1 == "/repos/kalcode/unwritten-chronicles/issues")) == 2
    end

    test "a forge failure is an error the brain can relay, not a crash", %{david: d} do
      forge(%{
        {"GET", "/repos/kalcode/unwritten-chronicles/issues"} => &Plug.Conn.send_resp(&1, 500, "")
      })

      log =
        capture_log(fn ->
          assert {:ok, %{error: error}} =
                   Tool.execute("code_board", %{"repo" => "chronicles"}, ctx(d))

          assert error =~ "500"
        end)

      assert log =~ "[dispatch]"
    end
  end

  describe "start_claude" do
    test "two issues: two jobs, two dispatches with the contract body", %{david: d} do
      forge()

      assert {:ok, %{repo: "unwritten-chronicles", started: started, refused: [], failed: []}} =
               Tool.execute(
                 "start_claude",
                 %{"repo" => "chronicles", "issues" => [31, 15]},
                 ctx(d)
               )

      assert [%{issue: 31, job_id: j31}, %{issue: 15, job_id: j15}] = started

      dispatches = for {"POST", @dispatch_path, body} <- forge_calls(), do: body

      assert dispatches == [
               %{
                 "ref" => "main",
                 "inputs" => %{
                   "repo" => "kalcode/unwritten-chronicles",
                   "issue" => "31",
                   "job_id" => to_string(j31)
                 },
                 "return_run_info" => true
               },
               %{
                 "ref" => "main",
                 "inputs" => %{
                   "repo" => "kalcode/unwritten-chronicles",
                   "issue" => "15",
                   "job_id" => to_string(j15)
                 },
                 "return_run_info" => true
               }
             ]

      assert %{status: "queued", run_id: 531, run_number: 31, user_id: uid} =
               Dispatch.get_job(j31)

      assert uid == d.id
      assert %{status: "queued", run_id: 515} = Dispatch.get_job(j15)
    end

    test "an issue with an active job is refused, the rest start", %{david: d} do
      forge()
      {:ok, running} = Dispatch.create_job(d.id, "kalcode/unwritten-chronicles", 31)

      assert {:ok, %{started: [%{issue: 15}], refused: [%{issue: 31, why: "already running"}]}} =
               Tool.execute(
                 "start_claude",
                 %{"repo" => "chronicles", "issues" => [31, 15]},
                 ctx(d)
               )

      issues = for {"POST", @dispatch_path, b} <- forge_calls(), do: b["inputs"]["issue"]
      assert issues == ["15"]
      assert [_, _] = Dispatch.list_jobs(d.id)
      assert Dispatch.get_job(running.id).status == "queued"
    end

    test "a closed or missing issue is refused without a job", %{david: d} do
      forge(%{
        {"GET", "/repos/kalcode/unwritten-chronicles/issues/30"} =>
          &Req.Test.json(&1, %{"number" => 30, "state" => "closed", "body" => "x"})
      })

      assert {:ok, %{started: [], refused: refused, failed: []}} =
               Tool.execute(
                 "start_claude",
                 %{"repo" => "chronicles", "issues" => [30, 404]},
                 ctx(d)
               )

      assert [%{issue: 30, why: why30}, %{issue: 404, why: why404}] = refused
      assert why30 =~ "closed"
      assert why404 =~ "no such issue"
      assert Dispatch.list_jobs(d.id) == []
    end

    test "a dispatch error fails the job (never left queued) and lists it", %{david: d} do
      forge(%{{"POST", @dispatch_path} => &Plug.Conn.send_resp(&1, 500, "")})

      log =
        capture_log(fn ->
          assert {:ok, %{started: [], failed: [%{issue: 31, why: why}]}} =
                   Tool.execute(
                     "start_claude",
                     %{"repo" => "chronicles", "issues" => [31]},
                     ctx(d)
                   )

          assert why =~ "500"
        end)

      assert log =~ "[dispatch] failed kalcode/unwritten-chronicles #31"
      assert [job] = Dispatch.list_jobs(d.id)
      assert job.status == "failed"
      assert job.reason =~ "500"
      assert Dispatch.active_job("kalcode/unwritten-chronicles", 31) == nil
    end

    test "notes are posted once on each issue, before the dispatch", %{david: d} do
      forge()

      assert {:ok, %{started: [_, _]}} =
               Tool.execute(
                 "start_claude",
                 %{
                   "repo" => "chronicles",
                   "issues" => [31, 15],
                   "notes" => "keep it small, don't touch the API"
                 },
                 ctx(d)
               )

      calls = forge_calls()

      comments =
        for {"POST", "/repos/kalcode/unwritten-chronicles/issues/" <> rest, body} <- calls,
            String.ends_with?(rest, "/comments"),
            do: {rest, body}

      assert comments == [
               {"31/comments",
                %{"body" => "From David, via Henry: keep it small, don't touch the API"}},
               {"15/comments",
                %{"body" => "From David, via Henry: keep it small, don't touch the API"}}
             ]

      # each issue's note lands before its dispatch
      order = for {m, p, _} <- calls, m == "POST", do: p

      assert Enum.find_index(order, &(&1 =~ "31/comments")) <
               Enum.find_index(order, &(&1 == @dispatch_path))
    end

    test "no notes, no comment", %{david: d} do
      forge()

      assert {:ok, %{started: [_]}} =
               Tool.execute("start_claude", %{"repo" => "chronicles", "issues" => [31]}, ctx(d))

      refute Enum.any?(forge_calls(), fn {_, p, _} -> String.ends_with?(p, "/comments") end)
    end

    test "a failed notes comment fails the job instead of starting without them", %{david: d} do
      forge(%{
        {"POST", "/repos/kalcode/unwritten-chronicles/issues/31/comments"} =>
          &Plug.Conn.send_resp(&1, 403, "")
      })

      capture_log(fn ->
        assert {:ok, %{started: [], failed: [%{issue: 31, why: why}]}} =
                 Tool.execute(
                   "start_claude",
                   %{"repo" => "chronicles", "issues" => [31], "notes" => "small"},
                   ctx(d)
                 )

        assert why =~ "notes"
      end)

      refute Enum.any?(forge_calls(), fn {m, p, _} -> m == "POST" and p == @dispatch_path end)
      assert [%{status: "failed"}] = Dispatch.list_jobs(d.id)
    end

    test "issue numbers are taken from numbers, strings and \"#31\", deduped", %{david: d} do
      forge()

      assert {:ok, %{started: [%{issue: 31}, %{issue: 15}], refused: refused}} =
               Tool.execute(
                 "start_claude",
                 %{"repo" => "chronicles", "issues" => ["#31", 31.0, "15", "soon", %{"n" => 2}]},
                 ctx(d)
               )

      assert [%{issue: "soon"}, %{issue: odd}] = refused
      assert is_binary(odd)
      assert Jason.encode!(refused)
    end

    test "a crash before a job exists is a failure for that issue only", %{david: d} do
      forge(%{
        {"GET", "/repos/kalcode/unwritten-chronicles/issues/31"} => fn _conn ->
          raise "boom"
        end
      })

      capture_log(fn ->
        assert {:ok, %{started: [%{issue: 15}], failed: [%{issue: 31}]}} =
                 Tool.execute(
                   "start_claude",
                   %{"repo" => "chronicles", "issues" => [31, 15]},
                   ctx(d)
                 )
      end)

      assert [%{issue: 15, status: "queued"}] = Dispatch.list_jobs(d.id)
    end
  end

  describe "claude_jobs" do
    test "the user's recent jobs with status, elapsed, PR and summary", %{david: d, tanya: t} do
      {:ok, a} = Dispatch.create_job(d.id, "kalcode/unwritten-chronicles", 31)

      {:ok, _, :changed} =
        Dispatch.apply_callback(a, %{
          status: "pr",
          pr_url: "https://forge.test/kalcode/unwritten-chronicles/pulls/40",
          summary: "Fixed the truncated action filter."
        })

      {:ok, _b} = Dispatch.create_job(d.id, "kalcode/personal-assistant", 23)
      {:ok, _} = Dispatch.create_job(t.id, "kalcode/personal-assistant", 24)

      assert {:ok, %{jobs: [newest, older]}} = Tool.execute("claude_jobs", %{}, ctx(d))
      assert %{repo: "personal-assistant", issue: 23, status: "queued", elapsed: elapsed} = newest
      assert elapsed == "under a minute"

      assert %{
               repo: "unwritten-chronicles",
               issue: 31,
               status: "pr",
               pr_url: "https://forge.test/kalcode/unwritten-chronicles/pulls/40",
               summary: "Fixed the truncated action filter."
             } = older

      assert is_binary(older.elapsed) and is_binary(older.finished)
      assert Jason.encode!(%{jobs: [newest, older]})
    end

    test "filters by repo (spoken) and issue, without a forge call", %{david: d} do
      forge()
      {:ok, _} = Dispatch.create_job(d.id, "kalcode/unwritten-chronicles", 31)
      {:ok, _} = Dispatch.create_job(d.id, "kalcode/unwritten-chronicles", 15)
      {:ok, _} = Dispatch.create_job(d.id, "kalcode/personal-assistant", 23)

      assert {:ok, %{jobs: [%{issue: 15}, %{issue: 31}]}} =
               Tool.execute("claude_jobs", %{"repo" => "chronicles"}, ctx(d))

      assert {:ok, %{jobs: [%{issue: 31}]}} =
               Tool.execute("claude_jobs", %{"repo" => "chronicles", "issue" => 31}, ctx(d))

      assert {:ok, %{jobs: [%{repo: "personal-assistant"}]}} =
               Tool.execute("claude_jobs", %{"repo" => "you"}, ctx(d))

      assert forge_calls() == []
    end

    test "at most ten, and a note when there are none", %{david: d} do
      assert {:ok, %{jobs: [], note: _}} = Tool.execute("claude_jobs", %{}, ctx(d))

      for n <- 1..12, do: Dispatch.create_job(d.id, "kalcode/x", n)
      assert {:ok, %{jobs: jobs}} = Tool.execute("claude_jobs", %{}, ctx(d))
      assert length(jobs) == 10
    end

    test "elapsed reads in plain words" do
      assert Tool.plain_duration(5) == "under a minute"
      assert Tool.plain_duration(60) == "1 minute"
      assert Tool.plain_duration(25 * 60 + 10) == "25 minutes"
      assert Tool.plain_duration(3600) == "1 hour"
      assert Tool.plain_duration(3600 + 20 * 60) == "1 hour and 20 minutes"
      assert Tool.plain_duration(3 * 86_400 + 5) == "3 days"
    end
  end

  describe "file_issue" do
    test "posts the title and body, labels by id, and returns number and url", %{david: d} do
      forge()

      assert {:ok, %{repo: "unwritten-chronicles", number: 99, url: url} = res} =
               Tool.execute(
                 "file_issue",
                 %{
                   "repo" => "chronicles",
                   "title" => "Chat scroll jumps",
                   "body" => "The chat jumps to the top on a new message.",
                   "labels" => ["Bug", "feature", "urgent"]
                 },
                 ctx(d)
               )

      assert url == "https://forge.test/kalcode/unwritten-chronicles/issues/99"
      assert res.skipped_labels == ["urgent"]

      assert [body] =
               for(
                 {"POST", "/repos/kalcode/unwritten-chronicles/issues", b} <- forge_calls(),
                 do: b
               )

      assert body == %{
               "title" => "Chat scroll jumps",
               "body" => "The chat jumps to the top on a new message.",
               "labels" => [10, 11]
             }
    end

    test "no labels asked, no label lookup", %{david: d} do
      forge()

      assert {:ok, %{number: 99} = res} =
               Tool.execute(
                 "file_issue",
                 %{"repo" => "chronicles", "title" => "T", "body" => "B"},
                 ctx(d)
               )

      refute Map.has_key?(res, :skipped_labels)
      refute Enum.any?(forge_calls(), fn {_, p, _} -> String.ends_with?(p, "/labels") end)
    end

    test "a title is required", %{david: d} do
      forge()

      assert {:ok, %{note: note}} =
               Tool.execute("file_issue", %{"repo" => "chronicles", "body" => "B"}, ctx(d))

      assert note =~ "title"

      refute Enum.any?(forge_calls(), fn {m, _, _} -> m == "POST" end)
    end
  end
end
