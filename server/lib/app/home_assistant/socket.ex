defmodule App.HomeAssistant.Socket do
  @moduledoc """
  The pure protocol state machine behind `App.HomeAssistant.Live`: Home Assistant's WebSocket
  API (`/api/websocket`) as `handle/3` — one decoded inbound message in, the new state plus the
  messages to send out. No I/O and no timers; the GenServer only shuttles frames, so every
  decision here is unit-tested with plain maps (spec §2.1).

  ## The conversation

    * `auth_required` → `%{type: "auth", access_token: token}`; `auth_invalid` → `:auth_failed`.
    * `auth_ok` → the five loads (area / device / entity registries, the Assist exposure list,
      `get_states`) and `subscribe_events` for `state_changed` plus the three
      `*_registry_updated` events, each with a fresh, increasing id.
    * When all five loads have answered, `Directory.build/2`. A refused exposure list builds
      with `exposed: nil` (everything non-hidden counts as exposed), warned once.
    * `state_changed` → `Directory.put_state/3`. One that lands while the first load is still in
      flight patches the pending states, so nothing between the snapshot and the build is lost.
    * A `*_registry_updated` event (or the backstop `refresh/1`) re-requests the registries and
      exposure and rebuilds over the current raw states. Only one reload is ever in flight: an
      update arriving mid-reload marks it dirty and ONE follow-up goes out when it lands, so a
      burst of registry events (an integration reloading) costs at most two round trips.
    * Unknown ids and message types are ignored.

  `disconnected/1` keeps the last directory (marked disconnected) across a reconnect; the next
  `auth_ok`'s full load brings it back to connected. The token is kept out of `inspect/1`.
  """

  require Logger

  alias App.HomeAssistant.Directory

  @derive {Inspect, except: [:token]}

  @commands %{
    areas: "config/area_registry/list",
    devices: "config/device_registry/list",
    entities: "config/entity_registry/list",
    exposed: "homeassistant/expose_entity/list",
    states: "get_states"
  }
  @full_load [:areas, :devices, :entities, :exposed, :states]
  @registry_load [:areas, :devices, :entities, :exposed]
  @subscriptions ~w(state_changed area_registry_updated device_registry_updated
                    entity_registry_updated)
  @registry_events ~w(area_registry_updated device_registry_updated entity_registry_updated)

  @backoff_s [1, 2, 5, 15, 30, 60]
  @auth_failed_retry_s 600

  defstruct token: nil,
            # :connecting | :authenticating | :loading | :ready | :auth_failed
            phase: :connecting,
            ha_version: nil,
            next_id: 1,
            # id => {:load, key} | :subscribe — the requests still owed an answer
            pending: %{},
            # ids of our subscribe_events; events carrying any other id are ignored
            subscriptions: MapSet.new(),
            # the one load in flight: %{kind: :full | :registries, got: %{key => payload}, started: DateTime}
            load: nil,
            reload_again?: false,
            directory: nil,
            exposure_warned?: false

  @type phase :: :connecting | :authenticating | :loading | :ready | :auth_failed
  @type t :: %__MODULE__{}

  @spec new(String.t()) :: t()
  def new(token) when is_binary(token), do: %__MODULE__{token: token}

  @spec directory(t()) :: Directory.t() | nil
  def directory(%__MODULE__{directory: dir}), do: dir

  @doc "Feed one decoded inbound message; returns the new state and the messages to send."
  @spec handle(t(), map(), DateTime.t()) :: {t(), [map()]}
  def handle(%__MODULE__{} = t, %{"type" => "auth_required"}, _now),
    do: {%{t | phase: :authenticating}, [%{type: "auth", access_token: t.token}]}

  def handle(%__MODULE__{} = t, %{"type" => "auth_ok"} = msg, now) do
    Logger.info("[home] socket connected (HA #{msg["ha_version"]})")
    t = %{t | phase: :loading, ha_version: msg["ha_version"]}
    {t, loads} = request(t, :full, now)
    {t, subs} = subscribe(t)
    {t, loads ++ subs}
  end

  def handle(%__MODULE__{} = t, %{"type" => "auth_invalid"}, _now) do
    Logger.error("[home] socket auth refused — HOME_ASSISTANT_TOKEN needs attention")
    {%{t | phase: :auth_failed}, []}
  end

  def handle(%__MODULE__{} = t, %{"type" => "result", "id" => id} = msg, now) do
    case Map.pop(t.pending, id) do
      {{:load, key}, pending} ->
        loaded(%{t | pending: pending}, key, msg, now)

      {:subscribe, pending} ->
        unless msg["success"] == true,
          do: Logger.warning("[home] subscribe refused: #{error_code(msg)}")

        {%{t | pending: pending}, []}

      {nil, _} ->
        {t, []}
    end
  end

  def handle(
        %__MODULE__{} = t,
        %{"type" => "event", "id" => id, "event" => %{"event_type" => type} = event},
        now
      ) do
    if MapSet.member?(t.subscriptions, id),
      do: event(t, type, event["data"], now),
      else: {t, []}
  end

  def handle(%__MODULE__{} = t, _msg, _now), do: {t, []}

  @doc """
  The backstop: re-request the registries and exposure (states stay live through events).
  A no-op until this connection's first directory, and while any load is in flight (that one
  is answering with fresh data anyway).
  """
  @spec refresh(t(), DateTime.t()) :: {t(), [map()]}
  def refresh(t, now \\ DateTime.utc_now())

  def refresh(%__MODULE__{phase: :ready, load: nil} = t, now), do: request(t, :registries, now)
  def refresh(%__MODULE__{} = t, _now), do: {t, []}

  @doc "An app-level `ping` (HA answers `pong`) to prove a quiet socket is alive; only once authed."
  @spec ping(t()) :: {t(), [map()]}
  def ping(%__MODULE__{phase: phase} = t) when phase in [:loading, :ready] do
    {t, id} = next_id(t)
    {t, [%{id: id, type: "ping"}]}
  end

  def ping(%__MODULE__{} = t), do: {t, []}

  @doc """
  The connection dropped: keep the last directory (marked disconnected), forget everything
  owed by the old connection, and restart the ids for the next one. A refused token stays
  `:auth_failed` so the retry waits.
  """
  @spec disconnected(t()) :: t()
  def disconnected(%__MODULE__{} = t) do
    %{
      t
      | phase: if(t.phase == :auth_failed, do: :auth_failed, else: :connecting),
        next_id: 1,
        pending: %{},
        subscriptions: MapSet.new(),
        load: nil,
        reload_again?: false,
        directory: t.directory && Directory.set_connected(t.directory, false)
    }
  end

  @doc "Seconds before reconnect attempt `attempt` (0-based): 1, 2, 5, 15, 30, then 60 s; 10 min after a refused token."
  @spec retry_delay_s(t(), non_neg_integer()) :: pos_integer()
  def retry_delay_s(%__MODULE__{phase: :auth_failed}, _attempt), do: @auth_failed_retry_s

  def retry_delay_s(%__MODULE__{}, attempt),
    do: Enum.at(@backoff_s, attempt, List.last(@backoff_s))

  # -- loads --

  defp request(t, kind, now) do
    keys = if kind == :full, do: @full_load, else: @registry_load

    {t, msgs} =
      Enum.reduce(keys, {t, []}, fn key, {t, msgs} ->
        {t, id} = next_id(t)

        {%{t | pending: Map.put(t.pending, id, {:load, key})},
         [%{id: id, type: @commands[key]} | msgs]}
      end)

    {%{t | load: %{kind: kind, got: %{}, started: now}}, Enum.reverse(msgs)}
  end

  defp subscribe(t) do
    {t, msgs} =
      Enum.reduce(@subscriptions, {t, []}, fn event_type, {t, msgs} ->
        {t, id} = next_id(t)

        t = %{
          t
          | pending: Map.put(t.pending, id, :subscribe),
            subscriptions: MapSet.put(t.subscriptions, id)
        }

        {t, [%{id: id, type: "subscribe_events", event_type: event_type} | msgs]}
      end)

    {t, Enum.reverse(msgs)}
  end

  defp next_id(%__MODULE__{next_id: id} = t), do: {%{t | next_id: id + 1}, id}

  # A result for a key the current load doesn't own can't happen (ids are only pending for the
  # one load in flight), but stay total.
  defp loaded(%__MODULE__{load: nil} = t, _key, _msg, _now), do: {t, []}

  defp loaded(%__MODULE__{load: load} = t, key, msg, now) do
    {t, value} = payload(t, key, msg)
    load = %{load | got: Map.put(load.got, key, value)}
    keys = if load.kind == :full, do: @full_load, else: @registry_load

    if Enum.all?(keys, &Map.has_key?(load.got, &1)),
      do: finish(%{t | load: load}, now),
      else: {%{t | load: load}, []}
  end

  defp payload(t, :exposed, %{"success" => true, "result" => %{"exposed_entities" => exposed}})
       when is_map(exposed),
       do: {t, exposed}

  defp payload(t, :exposed, _msg) do
    unless t.exposure_warned?,
      do:
        Logger.warning(
          "[home] exposure list refused — treating every non-hidden entity as exposed"
        )

    {%{t | exposure_warned?: true}, nil}
  end

  # States are held as a map until the build so a state_changed can patch them in flight.
  defp payload(t, :states, %{"success" => true, "result" => states}) when is_list(states),
    do: {t, Map.new(states, &{&1["entity_id"], &1})}

  defp payload(t, :states, msg) do
    Logger.warning("[home] get_states refused: #{error_code(msg)}; keeping the last states")
    {t, Map.new(raw_states(t), &{&1["entity_id"], &1})}
  end

  defp payload(t, _registry, %{"success" => true, "result" => list}) when is_list(list),
    do: {t, list}

  defp payload(t, key, msg) do
    Logger.warning("[home] #{@commands[key]} refused: #{error_code(msg)}")
    {t, []}
  end

  defp finish(%__MODULE__{load: %{kind: kind, got: got, started: started}} = t, now) do
    states = if kind == :full, do: Map.values(got.states), else: raw_states(t)

    dir =
      Directory.build(
        %{
          areas: got.areas,
          devices: got.devices,
          entities: got.entities,
          exposed: got.exposed,
          states: states
        },
        now
      )

    summary =
      "#{length(Directory.entries(dir))} in view, #{length(dir.areas)} areas in " <>
        "#{DateTime.diff(now, started, :millisecond)}ms"

    if kind == :full,
      do: Logger.info("[home] directory loaded: " <> summary),
      else: Logger.debug("[home] directory refreshed: " <> summary)

    t = %{t | directory: dir, load: nil, phase: :ready}

    if t.reload_again?,
      do: request(%{t | reload_again?: false}, :registries, now),
      else: {t, []}
  end

  defp raw_states(%__MODULE__{directory: nil}), do: []
  defp raw_states(%__MODULE__{directory: dir}), do: Directory.raw_states(dir)

  # -- events --

  defp event(t, "state_changed", %{"entity_id" => id} = data, _now) when is_binary(id) do
    case data["new_state"] do
      new when is_map(new) or is_nil(new) -> {put_state(t, id, new), []}
      _ -> {t, []}
    end
  end

  defp event(t, type, _data, now) when type in @registry_events, do: reload(t, now)
  defp event(t, _type, _data, _now), do: {t, []}

  defp put_state(t, id, new) do
    t = if t.directory, do: %{t | directory: Directory.put_state(t.directory, id, new)}, else: t

    case t.load do
      %{got: %{states: states}} = load ->
        states = if new, do: Map.put(states, id, new), else: Map.delete(states, id)
        %{t | load: %{load | got: %{load.got | states: states}}}

      _ ->
        t
    end
  end

  defp reload(%__MODULE__{load: load} = t, _now) when not is_nil(load),
    do: {%{t | reload_again?: true}, []}

  defp reload(%__MODULE__{phase: :ready} = t, now), do: request(t, :registries, now)
  defp reload(%__MODULE__{} = t, _now), do: {t, []}

  defp error_code(%{"error" => %{"code" => code}}), do: code
  defp error_code(_), do: "unknown error"
end
