defmodule App.Tools.Recall do
  @moduledoc "recall_memory: full-text search over the user's past conversations (FTS5 on turns)."
  @behaviour App.Tools.Tool

  @impl true
  def declarations do
    [
      %{
        name: "recall_memory",
        description:
          "Search your past conversations with this user for a topic — use when they " <>
            "reference something from before that isn't in your current context (\"that " <>
            "recipe we discussed\", \"what did I say about X last week\"). Returns dated " <>
            "snippets of what they said and what you answered.",
        parameters: %{
          type: "object",
          properties: %{
            query: %{type: "string", description: "A few topic keywords (not a sentence)."}
          },
          required: ["query"]
        }
      }
    ]
  end

  @impl true
  def execute("recall_memory", _args, %{user_id: nil}), do: {:ok, %{matches: []}}

  def execute("recall_memory", %{"query" => q}, ctx),
    do: {:ok, %{matches: App.Memory.search_turns(ctx.user_id, q)}}

  def execute("recall_memory", _args, _ctx), do: {:error, :missing_args}

  @impl true
  def bridge("recall_memory"), do: ["Let me think back—", "Digging through my notes—"]
end
