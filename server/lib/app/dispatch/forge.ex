defmodule App.Dispatch.Forge do
  @moduledoc """
  Forgejo adapter for Claude dispatch: list repos and issues, detect agent context files and open
  PRs, create issues and comments, and dispatch/inspect the `work-issue.yml` workflow in the
  dispatch repo. Config: `:app, :forge` -> `%{url:, token:, dispatch_repo:}` (absent =
  `:not_configured`; see `App.Config.forge?/0`). Req options are overridable via
  `:dispatch_req_opts` (test seam). Errors flatten to `:not_configured | :unauthorized |
  :not_found | {:http, status} | transport`; every call returns `{:ok, _}` or `{:error, _}`.
  """

  @default_dispatch_repo "kalcode/claude-dispatch"

  def list_repos do
    with {:ok, body} <- get("/user/repos", limit: 50) do
      {:ok,
       for r <- body do
         %{
           name: r["name"],
           full_name: r["full_name"],
           default_branch: r["default_branch"],
           open_issues: r["open_issues_count"]
         }
       end}
    end
  end

  @doc "Open issues only (`type=issues` excludes pull requests)."
  def list_issues(full_name) do
    with {:ok, body} <-
           get("/repos/#{full_name}/issues", state: "open", type: "issues", limit: 50) do
      {:ok, Enum.map(body, &normalize_issue/1)}
    end
  end

  @doc "Does the repo carry a CLAUDE.md or AGENTS.md on `branch`?"
  def has_context?(full_name, branch) do
    Enum.reduce_while(["CLAUDE.md", "AGENTS.md"], {:ok, false}, fn file, acc ->
      case get("/repos/#{full_name}/contents/#{file}", ref: branch) do
        {:ok, _} -> {:halt, {:ok, true}}
        {:error, :not_found} -> {:cont, acc}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  @doc "Bodies of the open PRs (to spot \"Closes #N\")."
  def open_prs(full_name) do
    with {:ok, body} <- get("/repos/#{full_name}/pulls", state: "open", limit: 50) do
      {:ok, Enum.map(body, &(&1["body"] || ""))}
    end
  end

  def create_issue(full_name, title, body, labels) do
    with {:ok, r} <-
           post("/repos/#{full_name}/issues", %{title: title, body: body, labels: labels}) do
      {:ok, %{number: r["number"], url: r["html_url"]}}
    end
  end

  def comment(full_name, n, body) do
    with {:ok, _} <- post("/repos/#{full_name}/issues/#{n}/comments", %{body: body}),
         do: {:ok, :posted}
  end

  def dispatch(full_name, n, job_id) do
    with {:ok, cfg} <- config(),
         {:ok, r} <-
           post(
             "/repos/#{dispatch_repo(cfg)}/actions/workflows/work-issue.yml/dispatches",
             %{
               ref: "main",
               inputs: %{repo: full_name, issue: to_string(n), job_id: to_string(job_id)},
               return_run_info: true
             }
           ) do
      {:ok, %{run_id: r["id"], run_number: r["run_number"]}}
    end
  end

  def run(run_id) do
    with {:ok, cfg} <- config(),
         {:ok, r} <- get("/repos/#{dispatch_repo(cfg)}/actions/runs/#{run_id}", []) do
      {:ok, %{status: r["status"], conclusion: r["conclusion"]}}
    end
  end

  @doc false
  def normalize_issue(i) do
    %{
      number: i["number"],
      title: i["title"],
      labels: Enum.map(i["labels"] || [], & &1["name"]),
      body: i["body"],
      pull_request: not is_nil(i["pull_request"]),
      comments: i["comments"]
    }
  end

  defp dispatch_repo(cfg), do: cfg[:dispatch_repo] || @default_dispatch_repo

  defp get(path, params), do: request(:get, path, params: params)
  defp post(path, json), do: request(:post, path, json: json)

  defp request(method, path, opts) do
    with {:ok, %{url: url, token: token}} <- config() do
      base = [
        method: method,
        url: "#{String.trim_trailing(url, "/")}/api/v1#{path}",
        headers: [{"authorization", "token #{token}"}],
        finch: App.Finch,
        receive_timeout: 8_000
      ]

      case Req.request(
             base ++
               App.Http.Retry.opts() ++ opts ++ Application.get_env(:app, :dispatch_req_opts, [])
           ) do
        {:ok, %{status: s, body: body}} when s in 200..299 -> {:ok, body}
        {:ok, %{status: 401}} -> {:error, :unauthorized}
        {:ok, %{status: 404}} -> {:error, :not_found}
        {:ok, %{status: s}} -> {:error, {:http, s}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp config do
    case Application.get_env(:app, :forge) do
      %{url: url, token: token} = cfg
      when is_binary(url) and url != "" and is_binary(token) and token != "" ->
        {:ok, cfg}

      _ ->
        {:error, :not_configured}
    end
  end
end
