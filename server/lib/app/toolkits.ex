defmodule App.Toolkits do
  @moduledoc """
  Registry for toolkits (`App.Toolkits.Toolkit`): enabled kits, the catalog line for the
  system prompt, pre-selection from the user's words, and opening a kit into a config.
  A kit's tools are always dispatchable (`App.Tools.execute/3` searches `all_tools/1`);
  opening one only decides whether their declarations are advertised to the brain.
  """
  require Logger

  @recent_window_s 600

  @doc "Kits that are configured and usable."
  @spec enabled(map()) :: [module()]
  def enabled(cfg) do
    cfg |> Map.get(:toolkits, []) |> Enum.filter(& &1.enabled?(cfg))
  end

  @doc "The enabled kit with this id (case-insensitive), or nil."
  @spec find(map(), term()) :: module() | nil
  def find(cfg, id) when is_binary(id) do
    id = id |> String.trim() |> String.downcase()
    Enum.find(enabled(cfg), &(String.downcase(&1.id()) == id))
  end

  def find(_cfg, _id), do: nil

  @doc "Every tool module of every enabled kit, open or not."
  @spec all_tools(map()) :: [module()]
  def all_tools(cfg), do: cfg |> enabled() |> Enum.flat_map(& &1.tools()) |> Enum.uniq()

  @doc "The system-prompt sentence listing the enabled kits (\"\" when none)."
  @spec catalog_line(map()) :: String.t()
  def catalog_line(cfg) do
    case enabled(cfg) do
      [] ->
        ""

      kits ->
        "More tools come in toolkits — open one with use_toolkit when a request needs it: " <>
          Enum.map_join(kits, "; ", &"#{&1.id()} (#{&1.summary()})") <> "."
    end
  end

  @doc """
  Enabled, not-yet-open kits whose `wants?/2` says the window text needs them. The window is the
  transcript plus the last two recent turns that are within 10 minutes of `now` (so "make them
  blue" follows "turn on the gaming lights").
  """
  @spec preselect(map(), String.t(), map(), DateTime.t()) :: [module()]
  def preselect(cfg, transcript, ctx, %DateTime{} = now) do
    text = Enum.join([transcript || "" | recent_texts(ctx, now)], " ")
    open = Map.get(cfg, :open_toolkits, [])

    for kit <- enabled(cfg),
        kit.id() not in open,
        Code.ensure_loaded?(kit) and function_exported?(kit, :wants?, 2),
        kit.wants?(text, ctx) do
      Logger.info("[toolkit] preselect #{kit.id()}")
      kit
    end
  end

  defp recent_texts(ctx, now) do
    ctx
    |> Map.get(:recent)
    |> List.wrap()
    |> Enum.take(-2)
    |> Enum.filter(fn t ->
      match?(%DateTime{}, Map.get(t, :inserted_at)) and
        abs(DateTime.diff(now, t.inserted_at)) <= @recent_window_s
    end)
    |> Enum.map(&(Map.get(&1, :user_text) || ""))
  end

  @doc "Add the kits' tools to `cfg.tools` and their ids to `cfg.open_toolkits` (idempotent)."
  @spec open(map(), [module()]) :: map()
  def open(cfg, kits) do
    Enum.reduce(kits, cfg, fn kit, acc ->
      %{
        acc
        | tools: Enum.uniq(acc.tools ++ kit.tools()),
          open_toolkits: Enum.uniq(acc.open_toolkits ++ [kit.id()])
      }
    end)
  end

  @spec open?(map(), String.t()) :: boolean()
  def open?(cfg, id), do: id in Map.get(cfg, :open_toolkits, [])

  @doc "The brain-input note telling it which kits are open and how to use them."
  @spec guidance_note([module()]) :: String.t()
  def guidance_note(kits),
    do: Enum.map_join(kits, "", &"(Toolkit open: #{&1.id()}. #{&1.guidance()})\n")
end
