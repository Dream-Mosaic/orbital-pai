defmodule App.Tools.HomeAssistant do
  @moduledoc """
  The house, in three brain-callable functions over the live directory
  (`App.HomeAssistant.directory/0`):

    * `home_control` — the user's own words ("gaming lights", "the fireplace", "basement") or
      exact entity_ids → `Resolve` → `Actions.plan` → ONE `call_service` per distinct
      `{domain, service, data}`. The common command is one tool call, not find-then-act.
    * `home_status` — reads state from the directory through the same resolver; no HTTP at all.
      With no targets it gives a short overview (rooms, what's on, what's open, what's playing).
    * `play_music` — Music Assistant, players read from the directory.

  Safety is STRUCTURAL: locks, alarm panels and garage-class covers have no action→service
  mapping anywhere (`App.HomeAssistant.Entities`), and the resolver refuses them in `:control`,
  so a control call on one comes back `view_only` — it can never act. Rooms and the whole house
  fan out to LIGHTS ONLY (the Basement holds the homelab outlets). A media action (play, pause,
  next, volume_set) resolves among media players only (`Resolve`'s `:media`): "pause the
  kitchen" is the kitchen's speaker, never its lights. Instance-wide (one house, both users;
  nothing user-scoped).

  Outcomes are honest and first-class: an `unavailable` target is never called and comes back
  `offline` (`unknown` is NOT offline — write-only Govee toggles sit there); an unsure name
  comes back `ask` with candidates; nothing found is `not_found`; a bare "the lights" is
  `which_room`; an action a device can't do is `cant` with a plain-English why; a call that
  doesn't answer within `:home_assistant_call_timeout_ms` is `cant` "may still happen", never a
  plain failure. While the house connection is down, every result carries `as_of` (state, and so
  "offline", is last-known). Keys appear only when non-empty, `note` is one sentence for the
  brain. Every failure flattens to `{:ok, %{note | error}}` the brain can relay — never a crash.
  No tool cache: the directory is live.

  After a successful on/off for a light, switch, input_boolean or fan, a fire-and-forget watch
  waits up to `:home_assistant_watch_ms` (default 5s; 0 = off) for the directory to show the new
  state and logs the devices that don't — so a flaky device shows up in the logs, never in the
  answer. Log lines (spec §2.7): one `[home] resolve` per target, one `[home] control` per call.
  """
  @behaviour App.Tools.Tool

  require Logger

  alias App.HomeAssistant
  alias App.HomeAssistant.Actions
  alias App.HomeAssistant.Directory
  alias App.HomeAssistant.Entities
  alias App.HomeAssistant.Media
  alias App.HomeAssistant.Resolve

  @unreachable "couldn't reach the home hub (the house connection isn't up yet)"
  @not_configured "the home hub isn't configured on this server"
  @hub_trouble "the home hub had trouble"
  # A timed-out call may still have reached HA, so it is never reported as a plain failure.
  @not_in_time "the home hub didn't answer in time — it may still happen"

  # Each list a result can carry is capped (the overview's, and status rows).
  @cap 25
  # One service call's budget (`:home_assistant_call_timeout_ms`): Req's 6s receive_timeout +
  # the cold-pool retries, inside the registry's 8s tool cap. Groups' calls run side by side.
  @call_timeout_ms 7_000
  @watch_poll_ms 500
  @watched_domains ~w(light switch input_boolean fan)
  @media_actions ~w(play pause next volume_set)
  @overview_on ~w(light switch fan input_boolean)
  @color_modes ~w(hs xy rgb rgbw rgbww)

  # `note` is one sentence: the first of these that applies, then the lights-only policy, then
  # offline.
  @notes [
    ask: "Ask which one — name the top two or three, then call again with the exact entity_id.",
    which_room: "Ask which room, then call again with it (e.g. \"kitchen lights\").",
    not_found:
      "Nothing in the house goes by that name — ask what it's called; if a close name fits, " <>
        "check with the user before using it.",
    view_only:
      "Locks, the alarm and the garage door are view-only: say you're not set up to operate " <>
        "them (you can report their state)."
  ]
  # A policy, never a claim about this call: "the fireplace was left alone" was false the moment
  # the user named the fireplace alongside a room.
  @lights_only "A room or the whole house switches only its lights, never plugs or switches"
  @named_apart "anything named on its own was handled separately"
  # Only a room/house ask that didn't itself say "lights" gets the policy line.
  @light_nouns ~w(light lights lamp lamps)

  @target_items %{type: "array", items: %{type: "string"}}

  @impl true
  def declarations do
    [
      %{
        name: "home_control",
        description:
          "Act on the smart home in ONE call. targets = the user's own words for each device, " <>
            "group or room (\"gaming lights\", \"the fireplace\", \"basement\", \"all the " <>
            "lights\") or an exact entity_id you were given — the server resolves names, rooms, " <>
            "typos and aliases, so don't search first. Several targets act together. The result " <>
            "says what was done, what's offline, what can't do that and why, and when to ask " <>
            "which one. Locks, the alarm and the garage door are view-only.",
        parameters: %{
          type: "object",
          properties: %{
            targets:
              Map.put(
                @target_items,
                :description,
                "The user's words for each device, group or room, or exact entity_ids."
              ),
            action: %{
              type: "string",
              enum: Actions.actions(),
              description:
                "on/off/toggle; set_brightness, brighten, dim; set_color, set_color_temp, " <>
                  "set_effect (lights); set_temperature (thermostat, °F); open, close, " <>
                  "set_position (blinds); set_speed (fans); volume_set, play, pause, next " <>
                  "(speakers); activate (scenes, scripts)."
            },
            value: %{
              type: "number",
              description:
                "set_brightness/set_position/set_speed/volume_set 0-100; brighten/dim step " <>
                  "(default 20); set_temperature °F; set_color_temp kelvin."
            },
            color: %{
              type: "string",
              description:
                "set_color: a color name (\"blue\", \"warm white\") or #rrggbb. " <>
                  "set_color_temp: warm, soft, neutral, cool or daylight."
            },
            effect: %{type: "string", description: "set_effect: the effect's name."}
          },
          required: ["targets", "action"]
        }
      },
      %{
        name: "home_status",
        description:
          "Read the house: \"is the fireplace on?\", \"what's on in the basement?\", \"what's " <>
            "the thermostat at?\", \"is the garage open?\". targets = the user's own words " <>
            "(devices, groups, rooms, \"all the lights\") or exact entity_ids; state keeps only " <>
            "devices in that state (\"what lights are on?\" = targets [\"all the lights\"], " <>
            "state \"on\"). No targets: a short overview — rooms, what's on, open and playing.",
        parameters: %{
          type: "object",
          properties: %{
            targets:
              Map.put(
                @target_items,
                :description,
                "What to read, in the user's words or as exact entity_ids. Omit for the overview."
              ),
            state: %{
              type: "string",
              description: "Only devices in this state, e.g. \"on\", \"open\", \"unavailable\"."
            }
          },
          required: []
        }
      },
      %{
        name: "play_music",
        description:
          "Play music through the smart home (Music Assistant). Give what to play (query) and, " <>
            "if the user names a room/speaker, the player. Infer media_type from how they " <>
            "phrase it (an artist, a specific song/track, an album, a playlist, or a radio " <>
            "station) — omit it if you're not sure and let Music Assistant guess. enqueue " <>
            "defaults to \"replace\" (play now); use \"add\" to queue at the end or \"next\" to " <>
            "play right after the current track. To pause, skip, change volume, or ask what's " <>
            "playing, use home_control on that speaker instead.",
        parameters: %{
          type: "object",
          properties: %{
            query: %{
              type: "string",
              description: "What to play — an artist, song, album, playlist, or station name."
            },
            player: %{
              type: "string",
              description:
                "Room or speaker name to play on (e.g. \"kitchen\"). Omit if there's only one " <>
                  "player or the user didn't say."
            },
            media_type: %{
              type: "string",
              enum: ["artist", "track", "album", "playlist", "radio"],
              description: "What kind of thing query refers to; omit if unsure."
            },
            enqueue: %{
              type: "string",
              enum: ["replace", "add", "next"],
              description:
                "replace (default, play now), add (queue at the end), or next (play right " <>
                  "after the current track)."
            }
          },
          required: ["query"]
        }
      }
    ]
  end

  @impl true
  def bridge("home_control"), do: ["On it.", "Sure — one sec.", "Doing that now."]
  def bridge("home_status"), do: ["Checking the house.", "One sec — looking."]
  def bridge("play_music"), do: ["Cueing that up.", "One sec — let's get that going.", "On it."]
  def bridge(_), do: []

  @impl true
  def execute("home_control", args, _ctx) do
    with_directory(fn dir ->
      targets = targets(args)
      action = args |> Map.get("action") |> str() |> then(&(&1 && String.downcase(&1)))

      cond do
        targets == [] ->
          {:ok,
           %{
             note:
               "home_control needs targets — the user's own words for each device, group or " <>
                 "room, e.g. [\"gaming lights\"]"
           }}

        action not in Actions.actions() ->
          {:ok, %{note: action_note(action)}}

        true ->
          {:ok, control(dir, targets, action, params(args))}
      end
    end)
  end

  def execute("home_status", args, _ctx) do
    with_directory(fn dir ->
      # HA's states are lowercase; "On" from the model must not read as "none of those are On".
      state = args |> Map.get("state") |> str() |> then(&(&1 && String.downcase(&1)))

      result =
        case {targets(args), state} do
          {[], nil} -> overview(dir)
          # A state with no targets reads across the whole house.
          {[], state} -> status(dir, ["everything"], state)
          {targets, state} -> status(dir, targets, state)
        end

      {:ok, put_as_of(result, dir)}
    end)
  end

  def execute("play_music", args, _ctx) do
    with_directory(fn dir ->
      case str(Map.get(args, "query")) do
        nil ->
          {:ok, %{note: "play_music needs a query — what you want to play"}}

        query ->
          dir
          |> Directory.raw_states()
          |> Enum.sort_by(& &1["entity_id"])
          |> Media.ma_players()
          |> play(
            query,
            str(Map.get(args, "player")),
            str(Map.get(args, "media_type")),
            str(Map.get(args, "enqueue")),
            dir.connected?
          )
          |> then(fn {:ok, result} -> {:ok, put_as_of(result, dir)} end)
      end
    end)
  end

  # The directory is the one read seam. Never loaded (cold boot, HA down since boot) → the
  # unreachable note and no HTTP call at all.
  defp with_directory(fun) do
    case HomeAssistant.directory() do
      {:ok, %Directory{} = dir} -> fun.(dir)
      {:error, :not_configured} -> {:ok, %{error: @not_configured}}
      _ -> {:ok, %{error: @unreachable}}
    end
  end

  # -- home_control --

  defp control(dir, targets, action, params) do
    mode = if action in @media_actions, do: :media, else: :control
    resolved = Enum.map(targets, &{&1, resolve(dir, &1, mode)})
    {acts, outcomes} = resolved |> Enum.flat_map(&outcomes(dir, &1)) |> split_acts()

    {offline, live} = acts |> Enum.uniq_by(& &1.entity_id) |> Enum.split_with(&offline?(dir, &1))
    planned = Enum.map(live, &{&1, Actions.plan(raw(dir, &1), action, params)})

    # One call per distinct {domain, service, data}, in first-seen order.
    planned_ok = for {e, {:ok, key}} <- planned, do: {key, e}
    keys = planned_ok |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    groups = for key <- keys, do: {key, for({^key, e} <- planned_ok, do: e)}

    refused = for {e, {:error, reason}} <- planned, do: refusal(e, reason, action, dir, params)
    called = call_groups(groups, action)
    watch_after(action, called, dir)

    (outcomes ++ Enum.map(offline, &{:offline, &1.name}) ++ refused ++ called)
    |> shape()
    |> put_note(disclaim?(resolved), dir.connected?)
    # Offline is decided from last-known state while the house connection is down.
    |> put_as_of(dir)
  end

  # One target's resolution → tagged outcomes; `{:act, entry}` entries are acted on.
  defp outcomes(_dir, {_t, {:ok, entries, _how}}), do: Enum.map(entries, &{:act, &1})

  defp outcomes(dir, {t, {:ambiguous, es}}),
    do: [{:ask, %{target: t, candidates: Enum.map(es, &candidate(dir, &1))}}]

  defp outcomes(_dir, {t, {:none, es}}),
    do: [{:not_found, %{target: t, close: Enum.map(es, & &1.name)}}]

  defp outcomes(_dir, {t, {:sensitive, []}}), do: [{:view_only, t}]
  defp outcomes(_dir, {_t, {:sensitive, es}}), do: Enum.map(es, &{:view_only, &1.name})
  defp outcomes(_dir, {_t, {:which_room, rooms}}), do: Enum.map(rooms, &{:which_room, &1})

  defp split_acts(outcomes) do
    {acts, rest} = Enum.split_with(outcomes, &match?({:act, _}, &1))
    {Enum.map(acts, &elem(&1, 1)), rest}
  end

  defp candidate(dir, e) do
    %{name: e.name, entity_id: e.entity_id, area: e.area, state: state_of(dir, e.entity_id)}
    |> drop_nils()
  end

  # A sensitive entry is view-only (its absent mapping is the safety model); anything else
  # that can't do the action gets a plain-English why.
  defp refusal(%{class: :sensitive_read_only} = e, :not_controllable, _action, _dir, _params),
    do: {:view_only, e.name}

  defp refusal(e, reason, action, dir, params),
    do: {:cant, %{name: e.name, why: why(reason, action, e, raw(dir, e), params)}}

  # Calls for different `{domain, service, data}` groups run side by side, each under its own
  # budget; a crash or timeout is a `cant`, never the caller's crash.
  defp call_groups([], _action), do: []

  defp call_groups(groups, action) do
    App.Conversations.TaskSup
    |> Task.Supervisor.async_stream_nolink(
      groups,
      fn {{domain, service, data}, entries} ->
        call(domain, service, Map.put(data, :entity_id, Enum.map(entries, & &1.entity_id)))
      end,
      max_concurrency: length(groups),
      timeout: Application.get_env(:app, :home_assistant_call_timeout_ms, @call_timeout_ms),
      on_timeout: :kill_task
    )
    |> Enum.zip(groups)
    |> Enum.flat_map(fn
      {{:ok, {:ok, _}}, {{_d, _s, data}, entries}} ->
        Enum.map(
          entries,
          &{:done, %{name: &1.name, entity_id: &1.entity_id, set: set(action, data)}}
        )

      {failed, {{domain, service, _data}, entries}} ->
        # A killed call never reached its own log line.
        with {:exit, reason} <- failed do
          Logger.warning(
            "[home] control #{Enum.map_join(entries, ",", & &1.entity_id)} " <>
              "#{domain}.#{service} error (#{inspect(reason)})"
          )
        end

        why = if timed_out?(failed), do: @not_in_time, else: @hub_trouble
        Enum.map(entries, &{:cant, %{name: &1.name, why: why}})
    end)
  end

  # Killed past its budget, or Req's own receive timeout: the request may have executed.
  defp timed_out?({:exit, :timeout}), do: true
  defp timed_out?({:ok, {:error, %Req.TransportError{reason: :timeout}}}), do: true
  defp timed_out?(_failed), do: false

  defp set(action, data) when data == %{}, do: action
  defp set(_action, data), do: data

  defp shape(outcomes) do
    [:done, :offline, :cant, :view_only, :ask, :not_found, :which_room]
    |> Enum.map(fn k -> {k, for({^k, v} <- outcomes, uniq: true, do: v)} end)
    |> Enum.reject(fn {_k, v} -> v == [] end)
    |> Map.new()
  end

  # One sentence: the most pressing thing the brain must do with this result.
  defp put_note(result, disclaim?, connected?) do
    offline? = Map.has_key?(result, :offline)

    note =
      first_note(result) ||
        (disclaim? and Map.has_key?(result, :done) and lights_only_note(offline?, connected?)) ||
        (offline? && offline_note(connected?)) ||
        (result == %{} && "Nothing matched — ask the user what they meant.")

    if note, do: Map.put(result, :note, note), else: result
  end

  defp lights_only_note(false, _connected?), do: "#{@lights_only}; #{@named_apart}."

  defp lights_only_note(true, connected?),
    do:
      "#{@lights_only} (#{@named_apart}), and nothing was sent to " <>
        "#{offline_ones(connected?)} — say which."

  defp offline_note(connected?),
    do: "Nothing was sent to #{offline_ones(connected?)} — say so plainly, never that it worked."

  defp offline_ones(true), do: "the offline ones"
  defp offline_ones(false), do: "the ones last seen offline (the house connection is down)"

  defp first_note(result),
    do: Enum.find_value(@notes, fn {key, note} -> Map.has_key?(result, key) && note end)

  defp disclaim?(resolved) do
    Enum.any?(resolved, fn
      {phrase, {:ok, _, how}} when how in [:room, :house] -> not light_words?(phrase)
      _ -> false
    end)
  end

  defp light_words?(phrase),
    do:
      phrase
      |> String.downcase()
      |> String.split(~r/[^a-z]+/, trim: true)
      |> Enum.any?(&(&1 in @light_nouns))

  defp action_note(nil),
    do: "home_control needs an action — one of: #{Enum.join(Actions.actions(), ", ")}"

  defp action_note(action),
    do:
      "#{inspect(action)} isn't an action I know — use one of: " <>
        Enum.join(Actions.actions(), ", ")

  # -- why an action can't be done (said back to the user) --

  defp why(:not_controllable, _action, %{class: :controllable}, _raw, _params),
    do: "it isn't a light, so it has no colours or effects"

  defp why(:not_controllable, _action, _e, _raw, _params),
    do: "it's view-only — I can read it but not control it"

  defp why(:unknown_action, action, e, _raw, _params),
    do: "#{action} isn't something #{kind(e.domain)} can do"

  defp why(:needs_value, action, _e, _raw, _params), do: needs(action)

  defp why(:no_color_support, _action, _e, raw, _params) do
    case light_does(raw) do
      :white -> "it only does warm-to-cool white, not colour"
      :brightness -> "it only does brightness, not colour"
      :onoff -> "it only turns on and off"
      _ -> "it can't do colours"
    end
  end

  defp why(:no_color_temp_support, _action, _e, raw, _params) do
    case light_does(raw) do
      :color -> "it does colours but not warm or cool white — try a colour"
      :brightness -> "it only does brightness, not warm or cool white"
      :onoff -> "it only turns on and off"
      _ -> "it can't do warm or cool white"
    end
  end

  defp why(:no_effects, _action, _e, _raw, _params), do: "it has no effects"

  defp why({:unknown_color, c}, _action, _e, _raw, _params),
    do: "I don't know the colour #{inspect(c)} — try a name like blue or warm white, or #rrggbb"

  defp why({:unknown_effect, list}, _action, _e, _raw, params),
    do:
      "it has no effect called #{inspect(params.effect)} — it has: " <>
        (list |> Enum.take(12) |> Enum.join(", "))

  defp why(reason, action, _e, _raw, _params), do: "can't #{action} (#{inspect(reason)})"

  defp needs("set_color"), do: "set_color needs a color — a name like blue, or #rrggbb"

  defp needs("set_color_temp"),
    do: "set_color_temp needs warm, soft, neutral, cool or daylight, or a kelvin value"

  defp needs("set_effect"), do: "set_effect needs the effect's name"
  defp needs("set_temperature"), do: "set_temperature needs a temperature in °F"
  defp needs(action), do: "#{action} needs a value from 0 to 100"

  defp light_does(raw) do
    modes = List.wrap(get_in(raw, ["attributes", "supported_color_modes"]))

    cond do
      Enum.any?(modes, &(&1 in @color_modes)) -> :color
      "color_temp" in modes -> :white
      "brightness" in modes -> :brightness
      "onoff" in modes -> :onoff
      true -> nil
    end
  end

  defp kind("light"), do: "a light"
  defp kind("switch"), do: "a switch"
  defp kind("input_boolean"), do: "a toggle"
  defp kind("fan"), do: "a fan"
  defp kind("media_player"), do: "a speaker or TV"
  defp kind("climate"), do: "a thermostat"
  defp kind("cover"), do: "a blind or cover"
  defp kind("scene"), do: "a scene"
  defp kind("script"), do: "a script"
  defp kind(_), do: "it"

  # -- home_status --

  defp status(dir, targets, state) do
    resolved = Enum.map(targets, &{&1, resolve(dir, &1, :status)})
    {entries, outcomes} = resolved |> Enum.flat_map(&outcomes(dir, &1)) |> split_acts()

    rows =
      entries
      |> Enum.uniq_by(& &1.entity_id)
      |> Enum.map(&row(dir, &1))
      |> Enum.filter(&(is_nil(state) or &1[:state] == state))

    result = outcomes |> shape() |> Map.put(:devices, Enum.take(rows, @cap))

    note =
      first_note(result) ||
        (state && rows == [] && "none of those are #{inspect(state)} right now") ||
        (length(rows) > @cap && "showing #{@cap} of #{length(rows)}")

    if note, do: Map.put(result, :note, note), else: result
  end

  defp row(dir, e) do
    row = dir |> raw(e) |> Entities.compact()
    row = if e.area, do: Map.put(row, :area, e.area), else: row
    if row[:state] == "unavailable", do: Map.put(row, :offline, true), else: row
  end

  defp overview(dir) do
    entries = Directory.entries(dir)

    %{
      rooms: Enum.take(dir.areas, @cap),
      on: names_in(dir, entries, @overview_on, "on"),
      open: names_in(dir, entries, ["cover"], "open"),
      playing: names_in(dir, entries, ["media_player"], "playing")
    }
  end

  # Names of the entries of these domains in this state; a group stands for its members.
  defp names_in(dir, entries, domains, state) do
    entries = for e <- entries, e.domain in domains, state_of(dir, e.entity_id) == state, do: e
    members = for %{group?: true, members: ms} <- entries, m <- ms, into: MapSet.new(), do: m

    entries
    |> Enum.reject(&MapSet.member?(members, &1.entity_id))
    |> Enum.map(& &1.name)
    |> Enum.sort()
    |> Enum.take(@cap)
  end

  defp put_as_of(result, %Directory{connected?: true}), do: result

  defp put_as_of(result, %Directory{} = dir),
    do: Map.put(result, :as_of, "#{ago(Directory.as_of(dir))} — the house connection is down")

  defp ago(%DateTime{} = at) do
    case max(DateTime.diff(DateTime.utc_now(), at, :minute), 0) do
      0 -> "less than a minute ago"
      1 -> "1 minute ago"
      n when n < 120 -> "#{n} minutes ago"
      n -> "#{div(n, 60)} hours ago"
    end
  end

  defp ago(_), do: "a while ago"

  # -- play_music --

  defp play([], _query, _player, _media_type, _enqueue, _connected?),
    do: {:ok, %{note: "no music players are set up (Music Assistant not configured?)"}}

  defp play(players, query, player_name, media_type, enqueue, connected?) do
    case Media.resolve_player(players, player_name) do
      {:error, :none} ->
        {:ok,
         %{
           note: "I don't see a speaker called #{player_name} — I have: #{player_names(players)}"
         }}

      {:error, :ambiguous} ->
        {:ok,
         %{
           note: "which room? I can play on: #{player_names(players)}",
           players: Enum.map(players, & &1.name)
         }}

      {:ok, %{state: "unavailable"} = p} ->
        {:ok, %{offline: [p.name], note: offline_note(connected?)}}

      {:ok, p} ->
        data =
          Media.play_media_data(query, media_type, enqueue) |> Map.put(:entity_id, p.entity_id)

        case call("music_assistant", "play_media", data) do
          {:ok, _} ->
            {:ok, %{playing: query, player: p.name, enqueue: data.enqueue}}

          {:error, reason} ->
            {:ok,
             %{error: "couldn't play that — the music service had trouble (#{inspect(reason)})"}}
        end
    end
  end

  defp player_names(players), do: players |> Enum.map(& &1.name) |> Enum.join(", ")

  # -- the silent no-op watch (spec §2.6) --

  defp watch_after(action, called, dir) when action in ["on", "off"] do
    ms = Application.get_env(:app, :home_assistant_watch_ms, 5_000)

    # `unknown` before the call = a write-only toggle that never reports; watching it is noise.
    ids =
      for {:done, %{entity_id: id}} <- called,
          Entities.domain(%{"entity_id" => id}) in @watched_domains,
          state_of(dir, id) != "unknown",
          do: id

    if ms > 0 and ids != [] do
      Task.Supervisor.start_child(App.Conversations.TaskSup, fn -> watch(ids, action, ms) end)
    end

    :ok
  end

  defp watch_after(_action, _called, _dir), do: :ok

  @doc false
  # Polls the directory until every id reports `expected` or `ms` runs out; logs each miss.
  # Runs in its own task after the answer is already on its way — it never changes it.
  @spec watch([String.t()], String.t(), non_neg_integer()) :: :ok | {:missed, [String.t()]}
  def watch(ids, expected, ms) do
    watch_loop(ids, expected, ms, System.monotonic_time(:millisecond) + ms)
  end

  defp watch_loop(ids, expected, ms, deadline) do
    pending =
      case HomeAssistant.directory() do
        {:ok, %Directory{} = dir} -> Enum.reject(ids, &(state_of(dir, &1) == expected))
        _ -> ids
      end

    left = deadline - System.monotonic_time(:millisecond)

    cond do
      pending == [] ->
        :ok

      left <= 0 ->
        for id <- pending do
          Logger.warning(~s([home] #{id} did not report "#{expected}" within #{span(ms)}))
        end

        {:missed, pending}

      true ->
        Process.sleep(min(@watch_poll_ms, left))
        watch_loop(pending, expected, ms, deadline)
    end
  end

  defp span(ms) when rem(ms, 1000) == 0, do: "#{div(ms, 1000)}s"
  defp span(ms), do: "#{ms}ms"

  # -- shared --

  # One greppable line per resolve decision (spec §2.7).
  defp resolve(dir, phrase, mode) do
    result = Resolve.resolve(dir, phrase, mode)
    Logger.info("[home] resolve #{inspect(phrase)} → #{describe(dir, result)}")
    result
  end

  defp describe(dir, {:ok, [e], how}),
    do: "#{e.entity_id} (#{how}#{if offline?(dir, e), do: ", offline"})"

  defp describe(dir, {:ok, es, how}) do
    noun = if Enum.all?(es, &(&1.domain == "light")), do: "lights", else: "devices"
    off = Enum.count(es, &offline?(dir, &1))
    "#{length(es)} #{noun} (#{how}#{if off > 0, do: ", #{off} offline"})"
  end

  defp describe(_dir, {:ambiguous, es}), do: "ambiguous #{ids(es)}"
  defp describe(_dir, {:none, es}), do: "none (close: #{inspect(Enum.map(es, & &1.name))})"
  defp describe(_dir, {:sensitive, es}), do: "view-only #{ids(es)}"
  defp describe(_dir, {:which_room, rooms}), do: "which room? #{inspect(rooms)}"

  defp ids(es), do: "[" <> Enum.map_join(es, ", ", & &1.entity_id) <> "]"

  # One greppable line per service call (spec §2.7).
  defp call(domain, service, data) do
    started = System.monotonic_time(:millisecond)
    result = HomeAssistant.call_service(domain, service, data)
    ms = System.monotonic_time(:millisecond) - started
    {ids, rest} = Map.pop(data, :entity_id)

    outcome =
      case result do
        {:ok, _} -> "ok in #{ms}ms"
        {:error, reason} -> "error in #{ms}ms (#{inspect(reason)})"
      end

    Logger.info(
      "[home] control #{ids |> List.wrap() |> Enum.join(",")} #{domain}.#{service} " <>
        "#{inspect(rest)} #{outcome}"
    )

    result
  end

  defp raw(dir, e), do: Directory.state(dir, e.entity_id)
  defp state_of(dir, id), do: get_in(Directory.state(dir, id) || %{}, ["state"])
  defp offline?(dir, e), do: state_of(dir, e.entity_id) == "unavailable"

  # The model's words for the targets: `targets` (a list, or a lone string) and/or a bare
  # `target`, blanks and non-strings dropped.
  defp targets(args) do
    (List.wrap(Map.get(args, "targets")) ++ List.wrap(Map.get(args, "target")))
    |> Enum.map(&str/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  # Actions.plan normalizes loosely typed values ("50", " Blue ") itself.
  defp params(args) do
    %{
      value: Map.get(args, "value"),
      color: str(Map.get(args, "color")),
      effect: str(Map.get(args, "effect"))
    }
  end

  defp drop_nils(map), do: map |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()

  # nil unless a non-blank string.
  defp str(v) when is_binary(v) do
    case String.trim(v) do
      "" -> nil
      s -> s
    end
  end

  defp str(_), do: nil
end
