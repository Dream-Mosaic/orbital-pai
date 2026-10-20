defmodule App.HomeAssistant.Resolve do
  @moduledoc """
  The user's words → the house's entities, in code (spec §2.3). Pure: it reads a `Directory` and
  does no I/O, so every rule here is pinned by the fixture eval (`resolve_test.exs`: the
  household's own phrases against a snapshot of the real house).

  Why it exists: v1 made the model turn "the pantry light" into an opaque entity_id through strict
  substring search, and the house's real names (no aliases, typos like "Pantry Lighy", light
  groups with no area) beat it. Now the model passes what the user said, and this decides.

  ## The order of questions

    1. An exact `entity_id` (Henry picking from a candidate list) passes straight through.
    2. House words ("all the lights", "everything") fan out. A bare "the lights" asks which room.
    3. `:control` only: a type word naming a sensitive domain (lock, alarm, garage door) gets the
       view-only answer, whatever else the phrase says. That path can only refuse, so it's loose.
    4. Names: act on a clear winner.
    5. Rooms: a phrase that is a room's name fans out to its lights (`:control`), or to everything
       in it (`:status`).
    6. Type words ("the thermostat"): the one entity of that type, if there is exactly one and no
       other word in the phrase fails to match it.
    7. Otherwise nothing acts. The candidates come back for Henry to ask about.

  `:control` only ever considers controllable entities, plus sensitive ones so it can refuse them.
  Sensors are never control targets. `:status` considers everything in view.

  ## Scoring

  Every name an entity answers to (its own name, aliases, its device's name, its name with a
  generic "switch"/"power switch" tail cut off, and, for a plural ask, the name a light group's
  bulbs share) is tokenized like the query. Query and name tokens pair one-to-one: exact pairs
  first, then pairs one typo apart, which count 0.75. The score is the mean of how much of the
  query and how much of the name got covered, so extra words cost on either side ("night lights"
  scores "Night Lights" 1.0, "Hall nightlight" 0.83). Names borrowed from the device or a cut tail
  count 0.9, exactly the gap, so a sibling that borrows a name never ties the entity that owns it
  (the "Ambient backlight" light over its power switch). On a plural ask a light group that
  matches every word gets +0.1. Act only when the top scores ≥ 0.85 and is ≥ 0.1 ahead.
  """

  alias App.HomeAssistant.Directory
  alias App.HomeAssistant.Directory.Entry

  @threshold 0.85
  @gap 0.1
  # Float slack for the gap: 1.0 - 0.9 is 0.0999…
  @eps 1.0e-9
  # ≤ 0.8 keeps "Nigh lights" a clear gap behind "Night Lights"; ≥ 0.7 keeps "Pantry Lighy" over
  # the threshold for "pantry light".
  @typo 0.75
  @borrowed 0.9
  @group_bonus 0.1

  @stopwords ~w(the my a an please)
  @compounds %{"nightlight" => ~w(night light)}
  @tails [~w(power switch), ~w(switch)]
  @light_nouns ~w(light lamp)
  # Words that don't change which room is meant ("all the lights in the kitchen").
  @room_filler ~w(all every in)
  # "all the lights in the house" is "all the lights".
  @house_filler ~w(in house home whole entire)
  # Sharing only these with a name doesn't make it a "did you mean".
  @generic ~w(light lamp switch plug power)

  # {words, kind}. The first hit wins, so the sensitive kinds come first (a phrase that names one
  # must refuse) and longer phrases before their tails.
  @types [
    {~w(door lock), :lock},
    {~w(deadbolt), :lock},
    {~w(lock), :lock},
    {~w(alarm), :alarm},
    {~w(garage door), :garage},
    {~w(garage), :garage},
    {~w(thermostat), :climate},
    {~w(blind), :blinds},
    {~w(shade), :blinds},
    {~w(curtain), :blinds},
    {~w(fan), :fan}
  ]
  # Bare "garage" is a room too ("garage lights"), so it's the door only as the last word
  # ("open the garage").
  @last_only [~w(garage)]
  @sensitive_kinds [:lock, :alarm, :garage]
  @kind_domains %{lock: "lock", alarm: "alarm_control_panel", climate: "climate", fan: "fan"}

  @type how :: :entity_id | :name | :alias | :room | :house | :type
  @type result ::
          {:ok, [Entry.t()], how}
          | {:ambiguous, [Entry.t()]}
          | {:none, [Entry.t()]}
          | {:sensitive, [Entry.t()]}
          | {:which_room, [String.t()]}

  @doc """
  Resolve one target phrase. `{:ambiguous, es}` carries at most 5 candidates and `{:none, es}`
  at most 3 close matches, best first. `{:sensitive, es}` (`:control` only) means view-only.
  """
  @spec resolve(Directory.t(), String.t(), :control | :status) :: result()
  def resolve(%Directory{} = dir, phrase, mode)
      when is_binary(phrase) and mode in [:control, :status] do
    id = String.trim(phrase)

    if Regex.match?(~r/^[a-z_]+\.[a-z0-9_]+$/, id),
      do: by_entity_id(dir, id, mode),
      else: by_words(dir, %{tokens: tokens(phrase), plural: plural_words(phrase)}, mode)
  end

  defp by_entity_id(dir, id, mode) do
    case Directory.get(dir, id) do
      nil -> {:none, []}
      %Entry{class: :sensitive_read_only} = e when mode == :control -> {:sensitive, [e]}
      e -> {:ok, [e], :entity_id}
    end
  end

  defp by_words(_dir, %{tokens: []}, _mode), do: {:none, []}

  defp by_words(dir, q, mode) do
    house(dir, q, mode) || which_room(dir, q) || (mode == :control && sensitive(dir, q)) ||
      by_name_or_place(dir, q, mode)
  end

  defp by_name_or_place(dir, q, mode) do
    pool = pool(dir, mode)
    room = room(dir, q, pool, mode)
    ranked = rank(dir, pool, q, room)

    named(ranked, q, room, mode) || room_result(room) || typed(dir, pool, q, mode) ||
      leftovers(ranked, q)
  end

  defp pool(dir, :control),
    do: Enum.filter(Directory.entries(dir), &(&1.class in [:controllable, :sensitive_read_only]))

  defp pool(dir, :status), do: Directory.entries(dir)

  # -- house, rooms --

  defp house(dir, q, mode) do
    case Enum.reject(q.tokens, &(&1 in @house_filler)) do
      ["everything"] when mode == :status -> {:ok, fan_out(Directory.entries(dir)), :house}
      t when t in [~w(everything), ~w(all light), ~w(every light)] -> {:ok, lights(dir), :house}
      _ -> nil
    end
  end

  # Henry doesn't know which room the speaker is in, so a bare "the lights" doesn't fan out.
  defp which_room(dir, %{tokens: [noun]}) when noun in @light_nouns do
    rooms = dir |> lights() |> Enum.map(& &1.area) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    {:which_room, Enum.sort(rooms)}
  end

  defp which_room(_dir, _q), do: nil

  defp lights(dir),
    do: dir |> Directory.entries() |> Enum.filter(&(&1.domain == "light")) |> fan_out()

  # A phrase that is a room's name, give or take filler and a light noun, is a room ask. It fans
  # out to LIGHTS ONLY in :control (the Basement holds the homelab outlets), and to everything in
  # the room in :status unless the phrase said lights. `entries` may be [] (no lights there).
  defp room(dir, q, pool, mode) do
    rest = Enum.reject(q.tokens, &(&1 in @light_nouns or &1 in @room_filler))
    lights_only? = mode == :control or Enum.any?(q.tokens, &(&1 in @light_nouns))
    area = rest != [] && Enum.find(dir.areas, &same_words?(rest, tokens(&1)))

    if area do
      es = Enum.filter(pool, &(&1.area == area and (not lights_only? or &1.domain == "light")))
      %{area: area, entries: fan_out(es)}
    end
  end

  defp room_result(%{entries: [_ | _] = es}), do: {:ok, es, :room}
  defp room_result(_), do: nil

  # A fan-out drops the members of any group it includes: the group already covers them.
  defp fan_out(es) do
    members = for %Entry{group?: true, members: ms} <- es, m <- ms, into: MapSet.new(), do: m
    es |> Enum.reject(&MapSet.member?(members, &1.entity_id)) |> Enum.sort_by(& &1.name)
  end

  defp same_words?(a, b), do: length(a) == length(b) and elem(score(a, b), 1) == []

  # -- type words --

  defp sensitive(dir, q) do
    case type_word(q.tokens) do
      {kind, _rest} when kind in @sensitive_kinds ->
        {:sensitive, dir |> Directory.entries() |> Enum.filter(&kind?(dir, &1, kind))}

      _ ->
        nil
    end
  end

  # Exactly one entity of the type, and (in :control) every other word matches its name or room.
  # "the bedroom thermostat" doesn't act on the living room's: Henry confirms instead.
  defp typed(dir, pool, q, mode) do
    with {kind, rest} <- type_word(q.tokens),
         [_ | _] = es <- Enum.filter(pool, &kind?(dir, &1, kind)) do
      case Enum.sort_by(es, &{length(unmatched_words(&1, rest)), &1.name}) do
        [e] ->
          if mode == :status or unmatched_words(e, rest) == [],
            do: {:ok, [e], :type},
            else: {:ambiguous, [e]}

        several ->
          {:ambiguous, Enum.take(several, 5)}
      end
    else
      _ -> nil
    end
  end

  defp type_word(toks) do
    Enum.find_value(@types, fn {words, kind} ->
      if rest = without(toks, words), do: {kind, rest}
    end)
  end

  # `toks` with one run of `words` cut out, or nil when it isn't there.
  defp without(toks, words) when words in @last_only do
    n = length(words)
    if Enum.take(toks, -n) == words, do: Enum.drop(toks, -n)
  end

  defp without(toks, words) do
    n = length(words)
    i = Enum.find(0..(length(toks) - n)//1, &(Enum.slice(toks, &1, n) == words))
    i && Enum.take(toks, i) ++ Enum.drop(toks, i + n)
  end

  defp kind?(dir, e, :garage), do: e.domain == "cover" and device_class(dir, e) == "garage"
  defp kind?(dir, e, :blinds), do: e.domain == "cover" and device_class(dir, e) != "garage"
  defp kind?(_dir, e, kind), do: e.domain == Map.fetch!(@kind_domains, kind)

  defp device_class(dir, e),
    do: get_in(Directory.state(dir, e.entity_id), ["attributes", "device_class"])

  defp unmatched_words(e, rest) do
    known = Enum.flat_map([e.name, e.area || "" | e.aliases], &tokens/1)
    elem(score(rest, known), 1)
  end

  # -- names --

  # One candidate per entity (its best-scoring name), best first; equal scores put the reachable
  # one first.
  defp rank(dir, pool, q, room) do
    pool
    |> Enum.map(&best(dir, &1, q, is_nil(room)))
    |> Enum.filter(&(&1 && &1.score > 0))
    |> Enum.sort_by(&{-&1.score, &1.offline?, &1.entry.name})
  end

  defp best(dir, e, q, borrow?) do
    scored =
      for {how, text, toks, weight} <- forms(dir, e, q, borrow?), toks != [] do
        {s, unmatched} = score(q.tokens, toks)
        bonus = if q.plural != [] and e.group? and unmatched == [], do: @group_bonus, else: 0.0
        %{entry: e, how: how, text: text, score: s * weight + bonus, unmatched: unmatched}
      end

    case scored do
      [] -> nil
      _ -> scored |> Enum.max_by(& &1.score) |> Map.put(:offline?, offline?(dir, e))
    end
  end

  # {how, source text, tokens, weight}. A phrase that is a room's name ("basement") can only be
  # claimed by an entity's own name or alias, never one borrowed from a device (the Basement
  # motion sensor's device is called "Basement").
  defp forms(dir, e, q, borrow?) do
    own = [{:name, e.name} | Enum.map(e.aliases, &{:alias, &1})]
    own = for {how, text} <- own, do: {how, text, tokens(text), 1.0}
    borrowed = if borrow?, do: [stripped(e.name), device_form(e)], else: []

    shared =
      if q.plural != [] and e.group?, do: [{:name, e.name, shared_tokens(dir, e), 1.0}], else: []

    Enum.reject(own ++ borrowed ++ shared, &is_nil/1)
  end

  defp stripped(name) do
    toks = tokens(name)

    Enum.find_value(@tails, fn tail ->
      n = length(tail)

      if length(toks) > n and Enum.take(toks, -n) == tail,
        do: {:name, name, Enum.drop(toks, -n), @borrowed}
    end)
  end

  defp device_form(%Entry{device_name: d, name: name}) when is_binary(d) and d != name,
    do: {:name, d, tokens(d), @borrowed}

  defp device_form(_e), do: nil

  # The name a light group's bulbs share ("Dining room light 2", "… 3" → "dining room light"):
  # how a household says "the dining room lights" when HA hides the bulbs behind the group.
  # Nested groups are left out, so "All Kitchen Lights" is still its bulbs' "kitchen light".
  defp shared_tokens(dir, %Entry{members: ms}) do
    ms
    |> Enum.map(&Directory.state(dir, &1))
    |> Enum.reject(&(is_nil(&1) or is_list(get_in(&1, ["attributes", "entity_id"]))))
    |> Enum.map(&tokens(get_in(&1, ["attributes", "friendly_name"]) || ""))
    |> common_prefix()
  end

  defp common_prefix([]), do: []
  defp common_prefix([first | rest]), do: Enum.reduce(rest, first, &prefix/2)

  defp prefix([x | a], [x | b]), do: [x | prefix(a, b)]
  defp prefix(_a, _b), do: []

  defp offline?(dir, e),
    do: match?(%{"state" => "unavailable"}, Directory.state(dir, e.entity_id))

  defp named([], _q, _room, _mode), do: nil

  defp named(ranked, q, room, mode) do
    case winner(ranked) do
      nil -> nil
      {:ambiguous, _} = asked -> asked
      c -> if room_beats?(c, q, room), do: nil, else: ok(c, mode)
    end
  end

  defp winner([top | _] = ranked) do
    if top.score + @eps >= @threshold do
      case Enum.take_while(ranked, &(top.score - &1.score < @gap - @eps)) do
        [only] -> only
        close -> twins(close)
      end
    end
  end

  # Identically named duplicates ("Arbol MaXtreme" twice) prefer the one that isn't unavailable.
  defp twins([c | _] = close) do
    if Enum.all?(close, &(tokens(&1.entry.name) == tokens(c.entry.name))) do
      case Enum.reject(close, & &1.offline?) do
        [] -> nil
        [only] -> only
        several -> {:ambiguous, several |> Enum.take(5) |> Enum.map(& &1.entry)}
      end
    end
  end

  # "office lights" means the office's lights, not one bulb named "Office Light" that matched
  # only once "lights" became "light". A group, or a name that says the plural itself, keeps it.
  defp room_beats?(c, q, room) do
    room != nil and room.entries != [] and q.plural != [] and not c.entry.group? and
      not Enum.all?(q.plural, &(&1 in words(c.text)))
  end

  defp ok(%{entry: %Entry{class: :sensitive_read_only} = e}, :control), do: {:sensitive, [e]}
  defp ok(c, _mode), do: {:ok, [c.entry], c.how}

  # Nothing acts. Candidates that matched every word (or tied at a winning score) are for Henry
  # to choose from; failing that, up to three that share a real word are the "did you mean".
  defp leftovers(ranked, q) do
    case Enum.filter(ranked, &(&1.unmatched == [] or &1.score + @eps >= @threshold)) do
      [] ->
        close = Enum.filter(ranked, &shares_real_word?(&1, q))
        {:none, close |> Enum.take(3) |> Enum.map(& &1.entry)}

      choices ->
        {:ambiguous, choices |> Enum.take(5) |> Enum.map(& &1.entry)}
    end
  end

  defp shares_real_word?(c, q), do: Enum.any?(q.tokens -- c.unmatched, &(&1 not in @generic))

  # -- normalizing and scoring --

  @doc false
  # What both sides of a match are compared as: downcased words without punctuation or articles,
  # a trailing "s" dropped on words over 3 letters, and "nightlight" split in two.
  @spec tokens(String.t()) :: [String.t()]
  def tokens(text) do
    for w <- words(text), t <- Map.get(@compounds, singular(w), [singular(w)]), do: t
  end

  defp words(text) do
    text
    |> String.downcase()
    |> String.replace(~r/['’]/u, "")
    |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
    |> Enum.reject(&(&1 in @stopwords))
  end

  defp singular(w) do
    if String.length(w) > 3 and String.ends_with?(w, "s") and not String.ends_with?(w, "ss"),
      do: binary_part(w, 0, byte_size(w) - 1),
      else: w
  end

  defp plural_words(phrase), do: Enum.filter(words(phrase), &(singular(&1) != &1))

  @doc false
  # Pair query and name tokens one-to-one (exact pairs first, then one-typo pairs) and score the
  # mean of query coverage and name coverage. Returns the query tokens left unpaired too.
  @spec score([String.t()], [String.t()]) :: {float(), [String.t()]}
  def score([], _name), do: {0.0, []}
  def score(query, []), do: {0.0, query}

  def score(query, name) do
    {exact, query_left, name_left} = pair(query, name, &==/2, 1.0)
    {typo, query_left, _} = pair(query_left, name_left, &near?/2, @typo)
    w = exact + typo
    {(w / length(query) + w / length(name)) / 2, query_left}
  end

  defp pair(query, name, same?, worth) do
    {w, left, pool} =
      Enum.reduce(query, {0.0, [], name}, fn t, {w, left, pool} ->
        case Enum.find_index(pool, &same?.(t, &1)) do
          nil -> {w, [t | left], pool}
          i -> {w + worth, left, List.delete_at(pool, i)}
        end
      end)

    {w, Enum.reverse(left), pool}
  end

  @doc false
  # One edit apart (a Levenshtein distance bounded at 1), and only between words of 4+ letters:
  # "lighy" ~ "light", "nigh" ~ "night", but never "fan" ~ "fin".
  @spec near?(String.t(), String.t()) :: boolean()
  def near?(a, b) do
    a != b and String.length(a) >= 4 and String.length(b) >= 4 and
      one_edit?(String.to_charlist(a), String.to_charlist(b))
  end

  defp one_edit?([c | a], [c | b]), do: one_edit?(a, b)
  defp one_edit?([_ | a] = aa, [_ | b] = bb), do: a == b or a == bb or aa == b
  defp one_edit?(a, b), do: length(a) + length(b) == 1
end
