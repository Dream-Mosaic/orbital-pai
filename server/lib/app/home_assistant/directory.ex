defmodule App.HomeAssistant.Directory do
  @moduledoc """
  The pure, in-memory model of the house: HA's area / device / entity registries, Assist
  exposure and live states folded into one struct. No I/O — the live client (later task) fetches
  the raw payloads and calls `build/2`; the resolver, planner and tools only ever read this.

  ## What Henry sees (spec §2.2)

  An entity is **in view** only if it is exposed to Assist, not hidden, not disabled, has no
  `entity_category` (config/diagnostic), is not a per-segment light, and classifies as something
  other than `:ignore`. An entity ABSENT from the exposure list is NOT exposed (that is what
  Assist itself does) — unless the list itself failed to load (`exposed: nil`), in which case
  everything non-hidden counts as exposed and `exposure_known?` is false.

  `states` keeps ALL raw states (not just in-view) so a state can be looked up for anything; an
  entry with no state is not visible (`entries/1`, `get/2`). A state with no registry entry
  (e.g. an orphaned switch) can still be in view if exposed.
  """

  alias App.HomeAssistant.Entities

  # Govee doesn't categorize its per-segment lights, so the pattern list is the filter.
  # Strings, compiled at runtime — OTP 28 can't escape compiled regexes into attributes.
  @segment_patterns ["segment \\d+$"]

  defmodule Entry do
    @moduledoc "One in-view entity: how Henry knows it (names, place) and what it may do."
    defstruct [
      :entity_id,
      :domain,
      :name,
      :device_name,
      :area,
      :class,
      aliases: [],
      group?: false,
      members: []
    ]

    @type t :: %__MODULE__{}
  end

  defstruct entries: %{},
            states: %{},
            areas: [],
            loaded_at: nil,
            connected?: true,
            # when the house connection dropped (nil while connected): states are last-known as of then
            disconnected_at: nil,
            exposure_known?: true

  @type t :: %__MODULE__{}

  @doc """
  Fold the raw registry/exposure/state payloads (string-keyed, as HA sends them) into a
  directory. `exposed` is the inner `exposed_entities` map, or `nil` when unknown.
  """
  @spec build(map(), DateTime.t()) :: t()
  def build(payloads, %DateTime{} = now) do
    areas = payloads |> Map.get(:areas, []) |> Map.new(&{&1["area_id"], &1["name"]})
    devices = payloads |> Map.get(:devices, []) |> Map.new(&{&1["id"], &1})
    registry = payloads |> Map.get(:entities, []) |> Map.new(&{&1["entity_id"], &1})
    exposed = Map.get(payloads, :exposed)
    states = payloads |> Map.get(:states, []) |> Map.new(&{&1["entity_id"], &1})

    entries =
      for {id, state} <- states,
          reg = Map.get(registry, id, %{}),
          in_view?(id, state, reg, exposed),
          into: %{} do
        {id, entry(id, state, reg, devices, areas)}
      end

    %__MODULE__{
      entries: entries,
      states: states,
      areas: areas |> Map.values() |> Enum.sort(),
      loaded_at: now,
      exposure_known?: not is_nil(exposed)
    }
  end

  @doc "In-view entries that currently have a state."
  @spec entries(t()) :: [Entry.t()]
  def entries(%__MODULE__{entries: entries, states: states}) do
    for {id, entry} <- entries, Map.has_key?(states, id), do: entry
  end

  @doc "The in-view entry for `entity_id` (nil when out of view or stateless)."
  @spec get(t(), String.t()) :: Entry.t() | nil
  def get(%__MODULE__{entries: entries, states: states}, entity_id) do
    if Map.has_key?(states, entity_id), do: Map.get(entries, entity_id)
  end

  @doc "The raw HA state map (`\"state\"`, `\"attributes\"`) for any entity, in view or not."
  @spec state(t(), String.t()) :: map() | nil
  def state(%__MODULE__{states: states}, entity_id), do: Map.get(states, entity_id)

  @spec raw_states(t()) :: [map()]
  def raw_states(%__MODULE__{states: states}), do: Map.values(states)

  @doc "Replace one entity's raw state; `nil` removes it."
  @spec put_state(t(), String.t(), map() | nil) :: t()
  def put_state(%__MODULE__{} = dir, entity_id, nil),
    do: %{dir | states: Map.delete(dir.states, entity_id)}

  def put_state(%__MODULE__{} = dir, entity_id, raw) when is_map(raw),
    do: %{dir | states: Map.put(dir.states, entity_id, raw)}

  @doc "Replace every raw state at once (a fresh snapshot); the entries are left as they are."
  @spec put_states(t(), [map()]) :: t()
  def put_states(%__MODULE__{} = dir, raw) when is_list(raw),
    do: %{dir | states: Map.new(raw, &{&1["entity_id"], &1})}

  @doc """
  Mark the house connection up or down. Going down stamps `disconnected_at` (`at`, default
  now) — only the FIRST time, since state events stopped at the first drop and repeated failed
  reconnects don't make the states any newer. Coming back up clears it.
  """
  @spec set_connected(t(), boolean(), DateTime.t() | nil) :: t()
  def set_connected(dir, connected?, at \\ nil)

  def set_connected(%__MODULE__{} = dir, true, _at),
    do: %{dir | connected?: true, disconnected_at: nil}

  def set_connected(
        %__MODULE__{connected?: false, disconnected_at: %DateTime{}} = dir,
        false,
        _at
      ),
      do: dir

  def set_connected(%__MODULE__{} = dir, false, at),
    do: %{dir | connected?: false, disconnected_at: at || DateTime.utc_now()}

  @doc """
  What the states are current as of: the drop time while disconnected (state events kept them
  live until then), else `loaded_at`.
  """
  @spec as_of(t()) :: DateTime.t() | nil
  def as_of(%__MODULE__{disconnected_at: %DateTime{} = at}), do: at
  def as_of(%__MODULE__{loaded_at: at}), do: at

  # -- the in-view rule (spec §2.2) --

  defp in_view?(id, state, reg, exposed) do
    Entities.classify(state) != :ignore and
      exposed?(id, exposed) and
      is_nil(reg["hidden_by"]) and
      is_nil(reg["disabled_by"]) and
      is_nil(reg["entity_category"]) and
      not segment?(friendly_name(state) || reg["name"] || "")
  end

  # Unknown exposure (the list failed to load): everything non-hidden counts as exposed.
  defp exposed?(_id, nil), do: true

  defp exposed?(id, exposed) do
    case Map.get(exposed, id) do
      %{"conversation" => true} -> true
      _ -> false
    end
  end

  defp segment?(name),
    do: Enum.any?(@segment_patterns, &Regex.match?(Regex.compile!(&1, "i"), String.trim(name)))

  # -- entry construction --

  defp entry(id, state, reg, devices, areas) do
    attrs = state["attributes"] || %{}
    device = Map.get(devices, reg["device_id"])
    # Only light groups: scenes and other domains also carry a list `entity_id` attribute.
    members =
      if Entities.domain(state) == "light" and is_list(attrs["entity_id"]),
        do: attrs["entity_id"],
        else: []

    %Entry{
      entity_id: id,
      domain: Entities.domain(state),
      name: friendly_name(state) || blank_to_nil(reg["name"]) || id,
      aliases: aliases(reg["aliases"]),
      device_name: device && (blank_to_nil(device["name_by_user"]) || device["name"]),
      area: Map.get(areas, reg["area_id"]) || (device && Map.get(areas, device["area_id"])),
      class: Entities.classify(state),
      group?: members != [],
      members: members
    }
  end

  defp friendly_name(state) do
    case state["attributes"] do
      %{"friendly_name" => n} -> blank_to_nil(n)
      _ -> nil
    end
  end

  defp aliases(list) when is_list(list) do
    for a <- list, is_binary(a), a = String.trim(a), a != "", do: a
  end

  defp aliases(_), do: []

  defp blank_to_nil(s) when is_binary(s), do: if((s = String.trim(s)) == "", do: nil, else: s)
  defp blank_to_nil(_), do: nil
end
