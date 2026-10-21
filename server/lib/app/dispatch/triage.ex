defmodule App.Dispatch.Triage do
  @moduledoc """
  Pure board triage: which open issues Claude may pick up, and as what kind of work.
  Issues are the normalized maps from `App.Dispatch.Forge.normalize_issue/1`. Whether a repo is
  design-gated (its CLAUDE.md says "HARD GATE" or "brainstorm") is detected elsewhere and passed in.
  """

  @idea ~w(idea ideas question discussion wontfix)
  @feature ~w(feature enhancement)
  @bug ~w(bug)
  @debt ~w(debt chore refactor)
  @rank %{bug: 0, debt: 1, feature: 2, design: 3}

  @type ctx :: %{design_gated?: boolean(), active_job?: boolean(), open_pr?: boolean()}

  @spec classify(map(), ctx()) ::
          {:candidate, :bug | :debt | :feature | :design} | {:skip, String.t()}
  def classify(issue, ctx) do
    labels = Enum.map(issue[:labels] || [], &String.downcase/1)

    cond do
      issue[:pull_request] in [true] -> {:skip, "is a pull request"}
      ctx[:open_pr?] -> {:skip, "PR already open"}
      ctx[:active_job?] -> {:skip, "job already active"}
      Enum.any?(labels, &(&1 in @idea)) -> {:skip, "idea"}
      blank?(issue[:body]) -> {:skip, "no description"}
      true -> kind(labels, ctx)
    end
  end

  defp kind(labels, ctx) do
    cond do
      Enum.any?(labels, &(&1 in @bug)) -> {:candidate, :bug}
      Enum.any?(labels, &(&1 in @debt)) -> {:candidate, :debt}
      Enum.any?(labels, &(&1 in @feature)) and ctx[:design_gated?] -> {:candidate, :design}
      Enum.any?(labels, &(&1 in @feature)) -> {:candidate, :feature}
      true -> {:skip, "no label"}
    end
  end

  defp blank?(body), do: not is_binary(body) or String.trim(body) == ""

  @doc "Orders candidates (maps with `:kind` and `:number`): bug, debt, feature, design; newest first."
  @spec order([map()]) :: [map()]
  def order(items), do: Enum.sort_by(items, &{Map.fetch!(@rank, &1.kind), -&1.number})
end
