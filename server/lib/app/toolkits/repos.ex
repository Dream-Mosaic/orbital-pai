defmodule App.Toolkits.Repos do
  @moduledoc """
  David's code as a toolkit: the issue boards on the forge (Forgejo) and starting Claude Code
  on an issue (`App.Tools.ClaudeDispatch`: code_board, start_claude, claude_jobs, file_issue).

  Enabled whenever the forge is configured (`App.Config.forge?/0`, cheap and pure). Whether a
  given USER may use it is decided inside the tools, which have `ctx.user_id`.
  """
  @behaviour App.Toolkits.Toolkit

  alias App.Dispatch.Board

  # The spec's vocabulary. The repos' own names come from `Board.phrases/0`, which a board read
  # publishes. Over-opening is the bias, as with the home kit.
  @vocab ~w(issue issues board boards ticket tickets bug bugs pr prs repo repos repository
            repositories branch branches claude forge) ++
           ["pull request", "pull requests", "claude code"]

  @impl true
  def id, do: "repos"

  @impl true
  def summary,
    do: "your code: the issue boards on your forge, and starting Claude Code on an issue"

  @impl true
  def enabled?(_cfg), do: App.Config.forge?()

  @impl true
  def tools, do: [App.Tools.ClaudeDispatch]

  @impl true
  def guidance do
    "You can see David's forge (code.clausens.cloud) and start Claude Code on its issues. " <>
      "Use code_board to see what's open — speak a short list (number, a few words each), " <>
      "candidates first, and say when a repo has no CLAUDE.md. Before start_claude, read back " <>
      "exactly which issues you'll start and wait for a yes. Pass anything extra David says as " <>
      "notes. Claude works unattended on a branch and opens a PR (or a draft, or asks a " <>
      "question on the issue); nothing merges without David. Use claude_jobs for \"how's " <>
      "Claude doing\". file_issue creates an issue — read the title back first. A started " <>
      "issue marked design_pr comes back as a design-doc PR, not code (feature work in a " <>
      "design-gated repo) — say so."
  end

  @impl true
  # No forge call: the repo names are a :persistent_term read.
  def wants?(text, _ctx) do
    padded = " " <> Board.normalize(text) <> " "
    Enum.any?(@vocab ++ Board.phrases(), &String.contains?(padded, " " <> &1 <> " "))
  end
end
