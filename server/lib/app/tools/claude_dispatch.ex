defmodule App.Tools.ClaudeDispatch do
  @moduledoc """
  The repos toolkit's tools (spec 2026-10-21-claude-dispatch-design.md, piece 1):

    * `code_board` (read). No repo: the repos with open issues, with counts and how many are
      candidates. A repo: its open issues triaged (`App.Dispatch.Board`), whether it has a
      CLAUDE.md, whether it's design-gated, and its active jobs.
    * `start_claude` (write). One job per issue. Each job is created, gets the notes comment,
      is dispatched to the workflow, and has its run recorded.
    * `claude_jobs` (read, database only). The user's recent jobs.
    * `file_issue` (write). Creates an issue, with label names turned into ids.

  Two gates come before any forge call. The user's canonical email must be on
  `:claude_dispatch_users`, else "that's not set up for you". The forge must be configured.

  `start_claude` never leaves a job `queued` that wasn't dispatched. A failed notes comment or a
  definite dispatch rejection (4xx/5xx, or a transport error before the request went out) marks
  the job `failed` with the reason (`App.Dispatch.set_status/3`, retried once). An ambiguous
  dispatch leaves it `queued`, since a run may exist. A 2xx with no run id is reported as
  started, with a note. A timeout after sending is reported under `uncertain`. The work runs in
  its own task, so the registry's tool cap can't kill it halfway through a job. A failure the
  answer reports is not announced again by the notifier, unless the answer came too late.

  Every failure flattens to `{:ok, %{error | note}}`. Log: one `[dispatch]` line per board
  read, start, refusal and failure. Reasons are status codes and atoms, never a token.
  """
  @behaviour App.Tools.Tool

  require Logger

  alias App.Dispatch
  alias App.Dispatch.{Board, Forge, Notifier, Repos}

  @not_yours "that's not set up for you"
  @not_configured "the forge isn't configured on this server"
  @issue_cap 20
  @repo_cap 10
  @jobs_cap 10
  @start_cap 10
  # The detached start work gets this long before the tool answers "still starting". It stays
  # inside start_claude's registry cap (timeout/1). `:dispatch_start_budget_ms` is the test seam.
  @start_budget_ms 18_000
  # Transport errors that prove the dispatch request never reached the forge. Anything else
  # after the request went out (a timeout, a dropped connection) may have started a run.
  @pre_send [
    :econnrefused,
    :nxdomain,
    :ehostunreach,
    :enetunreach,
    :pool_not_available,
    :unprocessed
  ]
  @no_run_id "the forge didn't return a run id"
  @may_have_started "may have started — check claude_jobs"

  @impl true
  def declarations do
    [
      %{
        name: "code_board",
        description:
          "See the issue boards on the forge. No repo: the repos with open issues, with counts " <>
            "and how many Claude could take. With a repo (the user's own words, e.g. \"the " <>
            "chronicles app\", \"Henry\"): its open issues, candidates first (a bug, debt or " <>
            "feature, or a design PR in a design-gated repo), then skips with why. Also says " <>
            "whether the repo has a CLAUDE.md and which Claude jobs are active.",
        parameters: %{
          type: "object",
          properties: %{
            repo: %{type: "string", description: "The repo in the user's words. Omit for all."}
          },
          required: []
        }
      },
      %{
        name: "start_claude",
        description:
          "Start Claude Code on issues of ONE repo, one job per issue. Claude works " <>
            "unattended on a branch and opens a PR (or a draft, or asks a question on the " <>
            "issue). Only after reading back exactly which issues and hearing a yes.",
        parameters: %{
          type: "object",
          properties: %{
            repo: %{type: "string", description: "The repo in the user's words."},
            issues: %{
              type: "array",
              items: %{type: "integer"},
              description: "The issue numbers to start."
            },
            notes: %{
              type: "string",
              description:
                "Anything extra the user said for Claude (\"keep it small\"). It's posted on " <>
                  "each issue."
            }
          },
          required: ["repo", "issues"]
        }
      },
      %{
        name: "claude_jobs",
        description:
          "How Claude is doing: the user's recent Claude jobs with status (queued, running, " <>
            "pr, draft, blocked, failed, usage_limit, lost), time taken, the PR link and " <>
            "Claude's summary. Optionally only one repo, or one issue.",
        parameters: %{
          type: "object",
          properties: %{
            repo: %{type: "string", description: "The repo in the user's words."},
            issue: %{type: "integer", description: "One issue number."}
          },
          required: []
        }
      },
      %{
        name: "file_issue",
        description:
          "Create an issue on a repo after reading the title back. Returns its number, so " <>
            "start_claude can follow.",
        parameters: %{
          type: "object",
          properties: %{
            repo: %{type: "string", description: "The repo in the user's words."},
            title: %{type: "string", description: "A short title."},
            body: %{type: "string", description: "What's wrong or wanted, in a few sentences."},
            labels: %{
              type: "array",
              items: %{type: "string"},
              description: "Label names, e.g. [\"bug\"]. Unknown ones are skipped."
            }
          },
          required: ["repo", "title", "body"]
        }
      }
    ]
  end

  @impl true
  def bridge("code_board"), do: ["Checking the board."]
  def bridge("start_claude"), do: ["Starting Claude."]
  def bridge(_), do: []

  @impl true
  # The overview reads several repos at once. start_claude makes up to three calls per issue.
  def timeout("code_board"), do: 15_000
  def timeout("start_claude"), do: 20_000
  def timeout("file_issue"), do: 12_000
  def timeout(_), do: 8_000

  @impl true
  def execute(name, args, ctx) do
    args = if is_map(args), do: args, else: %{}

    cond do
      not allowed?(ctx) ->
        Logger.info("[dispatch] #{name} refused: not set up for user #{inspect(ctx[:user_id])}")
        {:ok, %{error: @not_yours}}

      not App.Config.forge?() ->
        {:ok, %{error: @not_configured}}

      true ->
        run(name, args, ctx)
    end
  end

  # -- code_board --

  defp run("code_board", args, ctx) do
    case str(args["repo"]) do
      nil -> overview(aliases(ctx))
      phrase -> with_repo(phrase, ctx, &repo_board/1)
    end
  end

  defp run("start_claude", args, ctx) do
    # The budget runs from here: an uncached repo-list read comes out of it too.
    started_at = System.monotonic_time(:millisecond)
    {nums, bad} = issue_numbers(args["issues"])

    case str(args["repo"]) do
      nil ->
        {:ok, %{note: "start_claude needs the repo"}}

      _ when nums == [] and bad == [] ->
        {:ok, %{note: "start_claude needs the issue numbers"}}

      phrase ->
        with_repo(phrase, ctx, &start(&1, nums, bad, str(args["notes"]), ctx, started_at))
    end
  end

  defp run("claude_jobs", args, ctx) do
    jobs = Dispatch.list_jobs(ctx.user_id, limit: 50)

    case filter_repo(jobs, str(args["repo"]), aliases(ctx)) do
      {:ok, jobs} ->
        issue = int(args["issue"])
        jobs = if issue, do: Enum.filter(jobs, &(&1.issue == issue)), else: jobs
        now = DateTime.utc_now()
        rows = jobs |> Enum.take(@jobs_cap) |> Enum.map(&job_row(&1, now))
        {:ok, if(rows == [], do: %{jobs: [], note: "no Claude jobs yet"}, else: %{jobs: rows})}

      {:answer, result} ->
        {:ok, result}
    end
  end

  defp run("file_issue", args, ctx) do
    case {str(args["repo"]), str(args["title"])} do
      {nil, _} -> {:ok, %{note: "file_issue needs the repo"}}
      {_, nil} -> {:ok, %{note: "file_issue needs a title"}}
      {phrase, title} -> with_repo(phrase, ctx, &file(&1, title, args))
    end
  end

  defp run(name, _args, _ctx), do: {:error, {:unknown_function, name}}

  defp overview(aliases) do
    case Board.repos(aliases) do
      {:ok, repos} ->
        open = Enum.filter(repos, &(is_integer(&1.open_issues) and &1.open_issues > 0))

        rows =
          App.Conversations.TaskSup
          |> Task.Supervisor.async_stream_nolink(open, &summary/1,
            max_concurrency: 4,
            timeout: 12_000,
            on_timeout: :kill_task
          )
          |> Enum.zip(open)
          |> Enum.map(fn
            {{:ok, row}, _} -> row
            {{:exit, _}, r} -> %{repo: r.name, open: r.open_issues, error: "couldn't read it"}
          end)
          # A cached count can be stale: a repo whose live list came back empty isn't shown.
          |> Enum.reject(&(&1.open == 0 and not Map.has_key?(&1, :error)))
          |> Enum.sort_by(&{-Map.get(&1, :candidates, -1), -&1.open})

        Logger.info(
          "[dispatch] board overview: " <>
            Enum.map_join(rows, ", ", &"#{&1.repo} #{Map.get(&1, :candidates, "?")}/#{&1.open}")
        )

        shown = Enum.take(rows, @repo_cap)

        result =
          if rows == [],
            do: %{repos: [], note: "nothing open on any repo"},
            else: put_more(%{repos: shown}, length(rows) - length(shown))

        {:ok, result}

      {:error, reason} ->
        trouble("couldn't read the repo list", "repo list", reason)
    end
  end

  defp summary(repo) do
    case Board.board(repo) do
      {:ok, b} ->
        %{
          repo: repo.name,
          open: length(b.candidates) + length(b.skipped),
          candidates: length(b.candidates),
          has_context: b.context && b.context.has_context
        }
        |> drop_nils()

      {:error, reason} ->
        %{repo: repo.name, open: repo.open_issues, error: "couldn't read it (#{why(reason)})"}
    end
  end

  defp repo_board(repo) do
    case Board.board(repo) do
      {:ok, b} ->
        rows = Enum.map(b.candidates ++ b.skipped, &issue_row/1)
        shown = Enum.take(rows, @issue_cap)
        now = DateTime.utc_now()

        Logger.info(
          "[dispatch] board #{repo.full_name}: #{length(rows)} open, " <>
            "#{length(b.candidates)} candidates, context #{context_word(b.context)}"
        )

        %{
          repo: repo.name,
          open: length(rows),
          candidates: length(b.candidates),
          has_context: b.context && b.context.has_context,
          design_gated: b.context && b.context.design_gated,
          issues: shown,
          jobs: Enum.map(b.jobs, &active_row(&1, now))
        }
        |> drop_nils()
        |> put_more(length(rows) - length(shown))
        |> then(
          &if(b.context, do: &1, else: Map.put(&1, :note, "couldn't check for a CLAUDE.md"))
        )
        |> then(&{:ok, &1})

      {:error, reason} ->
        trouble("couldn't read the board", "board #{repo.full_name}", reason)
    end
  end

  defp context_word(nil), do: "unknown"
  defp context_word(%{has_context: false}), do: "none"
  defp context_word(%{design_gated: true}), do: "yes (design-gated)"
  defp context_word(_), do: "yes"

  defp issue_row(i) do
    verdict =
      case i.verdict do
        {:candidate, :design} -> "candidate (design PR)"
        {:candidate, kind} -> "candidate (#{kind})"
        {:skip, why} -> "skip (#{why})"
      end

    drop_nils(%{
      number: i.number,
      title: i.title,
      labels: i.labels,
      gist: gist(i.body),
      verdict: verdict
    })
  end

  @doc false
  # One line of the body for speaking: the first line that isn't a heading, without markdown,
  # links or URLs, cut at a word near 100 characters.
  def gist(body) when is_binary(body) do
    lines =
      body
      |> String.split(~r/\R/)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    line = Enum.find(lines, &(not String.starts_with?(&1, "#"))) || List.first(lines)

    case line && plain(line) do
      nil -> nil
      "" -> nil
      text -> cut(text, 100)
    end
  end

  def gist(_), do: nil

  defp plain(line) do
    line
    |> String.replace(~r/\[([^\]]*)\]\([^)]*\)/, "\\1")
    |> String.replace(~r{https?://\S+}, "")
    |> String.replace(~r/^(?:[#>*+-]+|\d+[.)])\s*/, "")
    |> String.replace(~r/[*`~_]{2,}|[`]/, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp cut(text, max) do
    if String.length(text) <= max do
      text
    else
      head = String.slice(text, 0, max)
      head = String.replace(head, ~r/\s+\S*$/, "")
      head <> "…"
    end
  end

  # -- start_claude --

  # Outcomes, one per issue:
  #   {:started, n, job, note | nil}   dispatched; note when the forge gave no run id
  #   {:uncertain, n, job}             the dispatch may have started a run; the job stays queued
  #   {:refused, n, why}               not started, nothing created
  #   {:failed, n, why, announce}      not started; `announce` is the job id whose notice was
  #                                    held back (the tool's answer says it instead), or nil
  defp start(repo, nums, bad, notes, ctx, started_at) do
    {now, over} = Enum.split(nums, @start_cap)
    user = App.Users.get(ctx.user_id)
    note_body = notes && "From #{first_name(user)}, via #{assistant(ctx)}: #{notes}"

    refused_up_front =
      Enum.map(bad, &{:refused, shown(&1), "not an issue number"}) ++
        Enum.map(over, &{:refused, &1, "at most #{@start_cap} at a time"})

    Enum.each(refused_up_front, fn {:refused, n, why} -> log_refused(repo, n, why) end)

    work = fn ->
      outcomes = Enum.map(now, &start_one(repo, &1, note_body, user.id))
      {outcomes, design_gated?(repo, outcomes)}
    end

    case run_detached(work, started_at) do
      {:ok, {outcomes, gated?}} ->
        {:ok, shape_start(repo, outcomes ++ refused_up_front, gated?)}

      :late ->
        Logger.warning("[dispatch] start #{repo.full_name} still running after the budget")

        {:ok,
         %{
           note:
             "the forge is slow, so I'm still starting them. Check claude_jobs in a minute " <>
               "to see which started"
         }}

      :crashed ->
        # Not the reason itself: an exit can carry a request, and a request carries the token.
        Logger.warning("[dispatch] start #{repo.full_name} crashed")
        {:ok, %{error: "starting Claude went wrong. Check claude_jobs to see what started"}}
    end
  end

  # Run the start work in its own task. The registry's cap kills the tool's process on a
  # timeout, and that must never strand a created job before its dispatch.
  #
  # A failure the tool's answer reports has its notice held back (fail/3 claims `notified_at`),
  # or the brain's answer and the wall would say it twice. If the answer misses the budget,
  # nobody heard, so the task announces those failures itself. An atomic handshake decides,
  # race-free, which side won: 0 pending, 1 delivered to the tool, 2 the tool gave up.
  # Everything the answer needs is computed in the task, before the handshake, so nothing slow
  # runs between the answer arriving and the tool returning.
  defp run_detached(work, started_at) do
    caller = self()
    ref = make_ref()
    gate = :atomics.new(1, [])

    {:ok, pid} =
      Task.Supervisor.start_child(App.Conversations.TaskSup, fn ->
        {outcomes, _} = result = work.()

        if :atomics.compare_exchange(gate, 1, 0, 1) == :ok do
          send(caller, {ref, result})
          # Backstop: a caller that died anyway (killed at the cap) never read it.
          unless Process.alive?(caller), do: announce_late(outcomes)
        else
          announce_late(outcomes)
        end
      end)

    mon = Process.monitor(pid)

    result =
      receive do
        {^ref, outcomes} ->
          {:ok, outcomes}

        {:DOWN, ^mon, :process, _, reason} when reason != :normal ->
          :crashed
      after
        max(budget() - (System.monotonic_time(:millisecond) - started_at), 0) ->
          if :atomics.compare_exchange(gate, 1, 0, 2) == :ok do
            :late
          else
            # Delivered just as the budget ran out: the message is already on its way.
            receive do
              {^ref, outcomes} -> {:ok, outcomes}
            after
              1_000 -> :late
            end
          end
      end

    Process.demonitor(mon, [:flush])
    result
  end

  defp budget, do: Application.get_env(:app, :dispatch_start_budget_ms, @start_budget_ms)

  defp announce_late(outcomes) do
    for {:failed, _n, _why, id} <- outcomes, is_integer(id) do
      Dispatch.release_notice(id)

      case Dispatch.get_job(id) do
        nil -> :ok
        job -> Notifier.notify(job)
      end
    end
  end

  defp design_gated?(repo, outcomes) do
    Enum.any?(outcomes, &match?({:started, _, _, _}, &1)) and
      match?({:ok, %{design_gated: true}}, guarded(fn -> Board.context(repo) end))
  end

  defp start_one(repo, n, notes, user_id) do
    full = repo.full_name

    outcome =
      try do
        with :ok <- not_active(n, Dispatch.active_job(full, n)),
             :ok <- startable(n, Forge.issue(full, n)),
             {:ok, job} <- create(n, Dispatch.create_job_unless_active(user_id, full, n)) do
          launch(repo, n, job, notes)
        end
      rescue
        # Before a job exists (launch/4 guards its own steps), so nothing is left queued.
        _ -> {:failed, n, "something went wrong starting it", nil}
      end

    case outcome do
      {:started, _, job, nil} ->
        Logger.info("[dispatch] start #{full} ##{n}: job #{job.id}")

      {:started, _, job, _note} ->
        Logger.warning("[dispatch] start #{full} ##{n}: job #{job.id}, no run id returned")

      {:uncertain, _, job} ->
        Logger.warning("[dispatch] uncertain #{full} ##{n}: job #{job.id} may have started")

      {:refused, _, why} ->
        log_refused(repo, n, why)

      {:failed, _, why, _} ->
        Logger.warning("[dispatch] failed #{full} ##{n}: #{why}")
    end

    outcome
  end

  defp not_active(_n, nil), do: :ok
  defp not_active(n, _job), do: {:refused, n, "already running"}

  defp startable(n, {:ok, %{pull_request: true}}), do: {:refused, n, "that's a pull request"}
  defp startable(_n, {:ok, %{state: "open"}}), do: :ok
  defp startable(n, {:ok, %{state: state}}), do: {:refused, n, "it's #{state}"}
  defp startable(n, {:error, :not_found}), do: {:refused, n, "no such issue"}

  defp startable(n, {:error, reason}),
    do: {:failed, n, "couldn't read the issue: #{why(reason)}", nil}

  defp create(_n, {:ok, job}), do: {:ok, job}
  defp create(n, {:error, {:active, _}}), do: {:refused, n, "already running"}
  defp create(n, {:error, _}), do: {:failed, n, "couldn't record the job", nil}

  # Only a definite "no" fails the job. A 2xx without a run id means the forge took it (the
  # callbacks carry the job id, and the watchdog's lost rule bounds a silent one). A request
  # that went out and got no answer may have started a run; failing it would make the end-state
  # guard drop its real callbacks, and invite a second run.
  defp launch(repo, n, job, notes) do
    full = repo.full_name

    case guarded(fn -> post_notes(full, n, notes) end) do
      :ok ->
        case guarded(fn -> Forge.dispatch(full, n, job.id) end) do
          {:ok, run} ->
            mark_dispatched(job, run, full, n)
            {:started, n, job, nil}

          {:error, reason} ->
            case dispatch_outcome(reason) do
              :accepted -> {:started, n, job, @no_run_id}
              :rejected -> fail(job, n, "the forge didn't start it: #{why(reason)}")
              :uncertain -> {:uncertain, n, job}
            end

          :raised ->
            {:uncertain, n, job}
        end

      {:error, reason} ->
        fail(job, n, "couldn't post the notes on the issue: #{why(reason)}")

      :raised ->
        fail(job, n, "something went wrong posting the notes")
    end
  end

  defp dispatch_outcome(r) when r in [:no_run_info, :bad_body], do: :accepted
  defp dispatch_outcome(r) when r in [:unauthorized, :not_found, :not_configured], do: :rejected
  defp dispatch_outcome({:http, _}), do: :rejected
  defp dispatch_outcome(%{reason: r}) when r in @pre_send, do: :rejected
  defp dispatch_outcome(_), do: :uncertain

  defp guarded(fun) do
    fun.()
  rescue
    _ -> :raised
  end

  # The job IS dispatched either way: its callback moves it on, only the run id would be missing.
  defp mark_dispatched(job, run, full, n) do
    case Dispatch.mark_dispatched(job, run) do
      {:ok, _} -> :ok
      {:error, _} -> run_id_lost(job, full, n)
    end
  rescue
    _ -> run_id_lost(job, full, n)
  end

  defp run_id_lost(job, full, n),
    do: Logger.warning("[dispatch] start #{full} ##{n}: job #{job.id} run id not recorded")

  defp post_notes(_full, _n, nil), do: :ok

  defp post_notes(full, n, body) do
    case Forge.comment(full, n, body) do
      {:ok, _} -> :ok
      err -> err
    end
  end

  # Hold the notice back first (this answer reports the failure), then mark the job failed,
  # retrying once. If it still can't be marked, the notice is released again, so the watchdog's
  # eventual `lost` gets announced, and the stranded job is logged.
  defp fail(job, n, why) do
    held = guarded(fn -> Dispatch.claim_notice(job.id) end) == true

    if mark_failed(job, why, 2) do
      {:failed, n, why, if(held, do: job.id)}
    else
      if held, do: guarded(fn -> Dispatch.release_notice(job.id) end)
      Logger.warning("[dispatch] job #{job.id} left queued: couldn't mark it failed")
      {:failed, n, why, nil}
    end
  end

  defp mark_failed(_job, _why, 0), do: false

  defp mark_failed(job, why, tries) do
    case guarded(fn -> Dispatch.set_status(job, "failed", why) end) do
      {:ok, _, _} -> true
      _ -> mark_failed(job, why, tries - 1)
    end
  end

  defp shape_start(repo, outcomes, gated?) do
    started =
      for {:started, n, job, note} <- outcomes do
        drop_nils(%{issue: n, job_id: job.id, note: note, design_gated: if(gated?, do: true)})
      end

    result = %{
      repo: repo.name,
      started: started,
      uncertain:
        for(
          {:uncertain, n, job} <- outcomes,
          do: %{issue: n, job_id: job.id, why: @may_have_started}
        ),
      refused: for({:refused, n, why} <- outcomes, do: %{issue: n, why: why}),
      failed: for({:failed, n, why, _} <- outcomes, do: %{issue: n, why: why})
    }

    if length(started) > 1,
      do: Map.put(result, :note, "Claude takes them one at a time; the others wait their turn"),
      else: result
  end

  defp log_refused(repo, n, why),
    do: Logger.info("[dispatch] refused #{repo.full_name} ##{n}: #{why}")

  @doc false
  # Issue numbers from what the model sent: integers, whole floats, "31" or "#31". Duplicates
  # are dropped. Returns {numbers, rejects}.
  def issue_numbers(list) when is_list(list) do
    {good, bad} =
      Enum.reduce(list, {[], []}, fn v, {good, bad} ->
        case int(v) do
          n when is_integer(n) and n > 0 -> {[n | good], bad}
          _ -> {good, [v | bad]}
        end
      end)

    {good |> Enum.reverse() |> Enum.uniq(), Enum.reverse(bad)}
  end

  def issue_numbers(nil), do: {[], []}
  def issue_numbers(one), do: issue_numbers([one])

  # A reject as the model sent it, if that's printable; anything else inspected.
  defp shown(v) when is_binary(v) or is_number(v), do: v
  defp shown(v), do: inspect(v)

  defp first_name(%{name: name}) when is_binary(name) do
    case String.split(name) do
      [first | _] -> first
      [] -> "David"
    end
  end

  defp first_name(_), do: "David"

  defp assistant(ctx) do
    case ctx[:config] do
      %{name: name} when is_binary(name) and name != "" -> name
      _ -> "Henry"
    end
  end

  # -- claude_jobs --

  defp filter_repo(jobs, nil, _aliases), do: {:ok, jobs}

  # Resolved against the repos the user has jobs on, so it needs no forge call.
  defp filter_repo(jobs, phrase, aliases) do
    known =
      jobs
      |> Enum.map(& &1.repo)
      |> Enum.uniq()
      |> Enum.map(&%{name: short(&1), full_name: &1})

    case Repos.resolve(known, phrase, aliases) do
      {:ok, %{full_name: full}} ->
        {:ok, Enum.filter(jobs, &(&1.repo == full))}

      {:ambiguous, many} ->
        {:answer, %{ask: Enum.map(many, & &1.name)}}

      {:none, _} ->
        {:answer, %{jobs: [], note: "no Claude jobs on a repo called \"#{phrase}\""}}
    end
  end

  defp job_row(job, now) do
    ended? = Dispatch.end_state?(job.status)
    until = if ended?, do: job.updated_at, else: now

    %{
      repo: short(job.repo),
      issue: job.issue,
      status: job.status,
      elapsed: plain_duration(DateTime.diff(until, job.inserted_at)),
      finished: if(ended?, do: ago(DateTime.diff(now, job.updated_at))),
      pr_url: job.pr_url,
      summary: job.summary,
      reason: job.reason
    }
    |> drop_nils()
  end

  defp active_row(job, now) do
    %{
      issue: job.issue,
      job_id: job.id,
      status: job.status,
      elapsed: plain_duration(DateTime.diff(now, job.inserted_at))
    }
  end

  defp ago(s) when s < 60, do: "just now"
  defp ago(s), do: plain_duration(s) <> " ago"

  @doc false
  def plain_duration(s) when s < 60, do: "under a minute"
  def plain_duration(s) when s < 3600, do: count(div(s, 60), "minute")

  def plain_duration(s) when s < 86_400 do
    hours = count(div(s, 3600), "hour")

    case div(rem(s, 3600), 60) do
      0 -> hours
      m -> "#{hours} and #{count(m, "minute")}"
    end
  end

  def plain_duration(s), do: count(div(s, 86_400), "day")

  defp count(1, unit), do: "1 #{unit}"
  defp count(n, unit), do: "#{n} #{unit}s"

  # -- file_issue --

  defp file(repo, title, args) do
    {ids, skipped} = label_ids(repo.full_name, strings(args["labels"]))
    body = str(args["body"]) || ""

    case Forge.create_issue(repo.full_name, title, body, ids) do
      {:ok, %{number: n, url: url}} ->
        Logger.info("[dispatch] filed #{repo.full_name} ##{n}")

        %{repo: repo.name, number: n, url: url}
        |> then(&if(skipped == [], do: &1, else: Map.put(&1, :skipped_labels, skipped)))
        |> then(&{:ok, &1})

      {:error, reason} ->
        trouble("couldn't create the issue", "file #{repo.full_name}", reason)
    end
  end

  defp label_ids(_full, []), do: {[], []}

  defp label_ids(full, names) do
    case Forge.labels(full) do
      {:ok, labels} ->
        by_name = Map.new(labels, &{String.downcase(to_string(&1.name)), &1.id})

        {ids, skipped} =
          Enum.reduce(names, {[], []}, fn name, {ids, skipped} ->
            case Map.get(by_name, String.downcase(name)) do
              nil -> {ids, [name | skipped]}
              id -> {[id | ids], skipped}
            end
          end)

        {ids |> Enum.reverse() |> Enum.uniq(), Enum.reverse(skipped)}

      {:error, reason} ->
        Logger.warning("[dispatch] labels #{full} unreadable: #{why(reason)}")
        {[], names}
    end
  end

  # -- shared --

  defp allowed?(ctx) do
    with id when is_integer(id) <- ctx[:user_id],
         %{email: email} when is_binary(email) <- App.Users.get(id) do
      allowed = Enum.map(Application.get_env(:app, :claude_dispatch_users, []), &down/1)
      String.downcase(email) in allowed
    else
      _ -> false
    end
  end

  defp down(s) when is_binary(s), do: s |> String.trim() |> String.downcase()
  defp down(_), do: nil

  defp aliases(ctx) do
    case ctx[:config] do
      %{repo_aliases: %{} = a} -> a
      _ -> %App.Config{}.repo_aliases
    end
  end

  defp with_repo(phrase, ctx, fun) do
    aliases = aliases(ctx)

    case Board.repos(aliases) do
      {:ok, repos} ->
        case Repos.resolve(repos, phrase, aliases) do
          {:ok, repo} ->
            fun.(repo)

          {:ambiguous, many} ->
            {:ok, %{ask: Enum.map(many, & &1.name)}}

          {:none, all} ->
            {:ok,
             %{
               note: "no repo on the forge goes by \"#{phrase}\"",
               repos: all |> Enum.map(& &1.name) |> Enum.sort()
             }}
        end

      {:error, reason} ->
        trouble("couldn't read the repo list", "repo list", reason)
    end
  end

  defp trouble(what, log_what, reason) do
    Logger.warning("[dispatch] #{log_what} failed: #{why(reason)}")
    {:ok, %{error: "#{what}: #{why(reason)}"}}
  end

  # Plain words for an adapter error. Only codes and atoms go in: nothing here can carry a token.
  defp why(:unauthorized), do: "the forge refused the token"
  defp why(:not_found), do: "not found on the forge"
  defp why(:not_configured), do: @not_configured
  defp why(:no_run_info), do: "the forge didn't say which run started"
  defp why(:bad_body), do: "the forge sent an answer I couldn't read"
  defp why({:http, status}), do: "the forge answered HTTP #{status}"
  defp why(%{reason: :timeout}), do: "the forge didn't answer in time"
  defp why(_), do: "couldn't reach the forge"

  defp put_more(map, n) when n > 0, do: Map.put(map, :more, n)
  defp put_more(map, _), do: map

  defp short(full), do: full |> String.split("/") |> List.last()

  defp str(s) when is_binary(s) do
    case String.trim(s) do
      "" -> nil
      t -> t
    end
  end

  defp str(_), do: nil

  defp strings(list) when is_list(list), do: list |> Enum.map(&str/1) |> Enum.reject(&is_nil/1)
  defp strings(_), do: []

  defp int(n) when is_integer(n), do: n
  defp int(f) when is_float(f) and f == trunc(f), do: trunc(f)

  defp int(s) when is_binary(s) do
    case Integer.parse(s |> String.trim() |> String.trim_leading("#")) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp int(_), do: nil

  defp drop_nils(map), do: map |> Enum.reject(fn {_, v} -> is_nil(v) end) |> Map.new()
end
