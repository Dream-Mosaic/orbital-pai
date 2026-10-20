defmodule App.Tools.UseToolkit do
  @moduledoc """
  `use_toolkit`: the brain opens a toolkit by name. Plumbing only — it returns the kit's guidance
  and tool names; the brain loop adds the kit's declarations from the next step (no bridge phrase).
  """
  @behaviour App.Tools.Tool

  alias App.Toolkits

  @impl true
  def declarations do
    [
      %{
        name: "use_toolkit",
        description:
          "Open a toolkit by name (the list is in your instructions) when the request needs tools you don't have yet. Its tools are available from your next step.",
        parameters: %{
          type: "object",
          properties: %{name: %{type: "string", description: "The toolkit's name."}},
          required: ["name"]
        }
      }
    ]
  end

  @impl true
  def execute("use_toolkit", args, ctx) do
    n = Map.get(args, "name") || ""
    n = if is_binary(n), do: n, else: ""

    case Toolkits.find(ctx.config, n) do
      nil ->
        {:ok,
         %{
           note: "no toolkit called \"#{n}\"",
           toolkits: Enum.map(Toolkits.enabled(ctx.config), & &1.id())
         }}

      kit ->
        if Toolkits.open?(ctx.config, kit.id()) do
          {:ok, %{already_open: kit.id()}}
        else
          names = kit.tools() |> Enum.flat_map(& &1.declarations()) |> Enum.map(& &1.name)
          {:ok, %{opened: kit.id(), guidance: kit.guidance(), tools: names}}
        end
    end
  end
end
