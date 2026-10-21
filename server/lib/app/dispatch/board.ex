defmodule App.Dispatch.Board do
  @moduledoc """
  The forge as the repos toolkit reads it.

    * `repos/1` — the repo list (`GET /user/repos`), cached 10 minutes.
    * `context/1` — whether a repo has a `CLAUDE.md`/`AGENTS.md` on its default branch, and
      whether either one design-gates it ("HARD GATE" or "brainstorm", any case). Cached
      10 minutes per repo.
    * `board/1` — one repo's open issues triaged for Claude (`App.Dispatch.Triage`), with its
      active jobs. Never cached, so a new issue or PR shows at once.

  The caches live in `App.Tools.Cache` and refresh lazily, from tool calls. There's no
  process of their own. Only `{:ok, _}` results are kept, so a forge error is retried on the
  next call.

  Each fresh repo list also publishes the words the kit preselects on (`phrases/0`) to
  `:persistent_term`, written only when they change. `App.Toolkits.Repos.wants?/2` reads them
  there, so preselecting a turn makes no forge call.
  """
  require Logger

  alias App.Dispatch
  alias App.Dispatch.{Forge, Repos, Triage}
  alias App.Tools.Cache

  @ttl_ms 10 * 60_000
  # Instance-wide entries in the tool cache, keyed {:forge, @cache_name, what}. Cache.purge/1
  # matches on that middle element, which is how forget/0 drops them all.
  @cache_name :dispatch_board
  @phrases {__MODULE__, :phrases}
  @context_files ["CLAUDE.md", "AGENTS.md"]
  @design_gate ~r/hard gate|brainstorm/i
  # Words that never preselect on their own, though a repo name or alias contains them:
  # pronoun and wake-name aliases ("you" and "Henry" are in nearly every turn), everyday
  # words, and Henry's own domains (the garden, lists, recipes, timers…), which have their
  # own tools. A multi-word phrase containing one ("garden planner") still counts.
  @not_topic ~w(you yourself me myself henry
                garden tracker trackers quality personal assistant planner players website native
                list lists recipe recipes timer timers reminder reminders weather music)
  # Single words of a repo name preselect only when they're this long. Shorter ones ("track",
  # "more", "text") are everyday words. The full name always counts.
  @min_word 6
  @min_phrase 4
  # Closing keywords in a PR body: "Closes #31", "fixes kalcode/x#31".
  @closes ~r/\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\b:?\s+([\w.-]+\/[\w.-]+)?#(\d+)\b/i
  # A Claude job's branch, claude/<n>-<slug>. A design-doc PR's body may only say "Refs #N".
  @claude_branch ~r{\Aclaude/(\d+)(?:-|\z)}

  @doc "The forge's repos (`Forge.list_repos/0` maps), cached 10 minutes."
  @spec repos(map()) :: {:ok, [map()]} | {:error, term()}
  def repos(aliases \\ %App.Config{}.repo_aliases) do
    case Cache.get(key(:repos)) do
      {:ok, repos} ->
        {:ok, repos}

      nil ->
        with {:ok, repos} = ok <- Forge.list_repos() do
          Cache.put(key(:repos), ok, @ttl_ms)
          publish_phrases(phrases_for(repos, aliases))
          ok
        end
    end
  end

  @doc """
  Read the repo list once, so a repo's name preselects the kit from the first turn after boot
  rather than after the first board read. Called off the watchdog's process shortly after
  startup. A forge that's down or unconfigured is logged and left to the next tool call.
  """
  @spec warm() :: :ok | {:error, term()}
  def warm do
    case repos() do
      {:ok, _} ->
        :ok

      {:error, reason} = err ->
        Logger.info("[dispatch] repo names not warmed: #{inspect_reason(reason)}")
        err
    end
  end

  @doc "`%{has_context: bool, design_gated: bool}` for a repo's default branch, cached."
  @spec context(map()) :: {:ok, map()} | {:error, term()}
  def context(%{full_name: full} = repo) do
    k = key({:context, full})

    case Cache.get(k) do
      {:ok, ctx} ->
        {:ok, ctx}

      nil ->
        with {:ok, _} = ok <- read_context(full, Map.get(repo, :default_branch) || "main") do
          Cache.put(k, ok, @ttl_ms)
          ok
        end
    end
  end

  defp read_context(full, branch) do
    Enum.reduce_while(@context_files, {:ok, %{has_context: false, design_gated: false}}, fn
      file, {:ok, acc} ->
        case Forge.file(full, file, branch) do
          {:ok, text} ->
            gated = acc.design_gated or Regex.match?(@design_gate, text)
            {:cont, {:ok, %{has_context: true, design_gated: gated}}}

          {:error, :not_found} ->
            {:cont, {:ok, acc}}

          {:error, _} = err ->
            {:halt, err}
        end
    end)
  end

  @doc """
  One repo's open issues, triaged: `{:ok, %{context, candidates, skipped, jobs}}`. Candidates
  come in `Triage.order/1` order, each with `:kind`. Skips come newest first. Each issue
  carries its `:verdict`. If the context files can't be read, `context` is nil and the design
  gate counts as off.
  """
  @spec board(map()) :: {:ok, map()} | {:error, term()}
  def board(%{full_name: full} = repo) do
    with {:ok, issues} <- Forge.list_issues(full),
         {:ok, prs} <- Forge.open_prs(full) do
      context =
        case context(repo) do
          {:ok, ctx} ->
            ctx

          {:error, reason} ->
            Logger.warning("[dispatch] context #{full} unreadable: #{inspect_reason(reason)}")
            nil
        end

      jobs = Dispatch.active_jobs(full)
      active = MapSet.new(jobs, & &1.issue)
      closed_by_pr = pr_issue_refs(prs, full)

      tri = %{
        design_gated?: (context && context.design_gated) || false,
        active_job?: false,
        open_pr?: false
      }

      triaged =
        for i <- issues do
          ctx = %{
            tri
            | active_job?: MapSet.member?(active, i.number),
              open_pr?: MapSet.member?(closed_by_pr, i.number)
          }

          Map.put(i, :verdict, Triage.classify(i, ctx))
        end

      {cands, skips} = Enum.split_with(triaged, &match?({:candidate, _}, &1.verdict))

      {:ok,
       %{
         context: context,
         candidates:
           cands |> Enum.map(&Map.put(&1, :kind, elem(&1.verdict, 1))) |> Triage.order(),
         skipped: Enum.sort_by(skips, &(-&1.number)),
         jobs: jobs
       }}
    end
  end

  @doc false
  # Issues an open PR already covers: the ones its body closes in this repo (a cross-repo
  # "kalcode/other#3" doesn't count), and the one its claude/<n>- head branch was made for.
  def pr_issue_refs(prs, full_name) do
    me = String.downcase(full_name)

    closed =
      for %{body: body} <- prs,
          is_binary(body),
          [_, repo, n] <- Regex.scan(@closes, body),
          String.downcase(repo) in ["", me],
          do: String.to_integer(n)

    branches =
      for %{head: head} <- prs,
          is_binary(head),
          [_, n] <- [Regex.run(@claude_branch, head)],
          do: String.to_integer(n)

    MapSet.new(closed ++ branches)
  end

  @doc """
  The words the kit preselects on: each repo's name as a phrase ("unwritten chronicles"), the
  long words in it ("chronicles"), and the alias keys, except pronouns and the assistant's own
  name. Published by `repos/1`, `[]` until the first read after boot.
  """
  @spec phrases() :: [String.t()]
  def phrases, do: :persistent_term.get(@phrases, [])

  @doc false
  def phrases_for(repos, aliases) do
    names =
      Enum.flat_map(repos, fn r ->
        ws = Repos.words(r.name || "")
        [Enum.join(ws, " ") | Enum.filter(ws, &(String.length(&1) >= @min_word))]
      end)

    (names ++ Enum.map(Map.keys(aliases), &normalize/1))
    |> Enum.filter(&(String.length(&1) >= @min_phrase))
    |> Enum.reject(&(&1 in @not_topic))
    |> Enum.uniq()
    |> Enum.sort()
  end

  # A :persistent_term write makes every process check its heap for the old term, so it only
  # happens when the list changed.
  defp publish_phrases(phrases) do
    unless :persistent_term.get(@phrases, nil) == phrases,
      do: :persistent_term.put(@phrases, phrases)
  end

  @doc false
  @spec normalize(String.t() | nil) :: String.t()
  def normalize(nil), do: ""

  def normalize(text) when is_binary(text),
    do: text |> String.downcase() |> String.replace(~r/[^\p{L}\p{N}]+/u, " ") |> String.trim()

  @doc false
  # Test seam: drop the cached repo list and context files, and the published phrases.
  def forget do
    Cache.purge(@cache_name)
    :persistent_term.erase(@phrases)
    :ok
  end

  defp key(what), do: {:forge, @cache_name, what}

  defp inspect_reason({:http, s}), do: "HTTP #{s}"
  defp inspect_reason(r) when is_atom(r), do: Atom.to_string(r)
  defp inspect_reason(_), do: "transport error"
end
