defmodule App.Tools.Garden do
  @moduledoc """
  The garden-book tool: record plants loosely (only a name is needed), log check-in notes,
  read the garden back, and retire plants per-plant or by season — history kept in past
  seasons. The garden is SHARED BY DEFAULT (like lists) — `App.Garden.Target` resolves who a
  call lands on and every result reports `assigned` so the brain reads it back ("added five
  tomato plants to the household garden"). Date args (`planted_on`/`noted_on`) are ISO date
  strings resolved by the brain (same contract as reminders' `due_at`); anything unparseable
  is simply stored as nil — nothing on a plant is required except its name.
  """
  @behaviour App.Tools.Tool

  alias App.Garden
  alias App.Garden.Target
  alias App.Users

  @impl true
  def declarations do
    [
      %{
        name: "add_plant",
        description:
          "Record a plant in the garden book. Only a name is needed (\"the tomatoes in the " <>
            "back\") — include species/location/count/planted_on ONLY if the user mentioned " <>
            "them. The garden is SHARED by default.",
        parameters: %{
          type: "object",
          properties: %{
            name: %{
              type: "string",
              description: "The plant, in the user's words, e.g. \"the tomatoes in the back\"."
            },
            species: %{type: "string", description: "Species/variety, if mentioned."},
            location: %{
              type: "string",
              description: "Where it's planted (\"back bed\", \"windowsill\"), if mentioned."
            },
            count: %{type: "integer", description: "How many were planted, if mentioned."},
            planted_on: %{
              type: "string",
              description: "Planting date as an ISO date (e.g. 2026-07-11), if mentioned."
            },
            for: %{
              type: "string",
              description:
                "Whose garden. Omit for the shared household garden (the default). " <>
                  "Use \"me\"/\"my\" for personal. Use a person's name for theirs."
            }
          },
          required: ["name"]
        }
      },
      %{
        name: "note_plant",
        description:
          "Log a check-in note on a plant (\"the tomatoes look leggy\"). Matches the plant " <>
            "by name or species.",
        parameters: %{
          type: "object",
          properties: %{
            plant: %{type: "string", description: "Which plant, e.g. \"the tomatoes\"."},
            note: %{type: "string", description: "The observation to log."},
            noted_on: %{
              type: "string",
              description: "The date it was observed, ISO (e.g. 2026-07-11). Omit for undated."
            }
          },
          required: ["plant", "note"]
        }
      },
      %{
        name: "list_garden",
        description:
          "Read back what's growing (name, planted date, location/count, latest note). " <>
            "Pass include: \"archived\" to also get past seasons.",
        parameters: %{
          type: "object",
          properties: %{
            include: %{
              type: "string",
              description:
                "\"archived\" (or \"past\") to include past seasons. Omit for active only."
            }
          },
          required: []
        }
      },
      %{
        name: "archive_plant",
        description:
          "Retire ONE plant to past seasons (\"the basil bolted\"). The record is kept as " <>
            "history under a season (default: this year).",
        parameters: %{
          type: "object",
          properties: %{
            plant: %{type: "string", description: "Which plant, e.g. \"the basil\"."},
            season: %{
              type: "string",
              description:
                "Season label if the user names one (e.g. \"Summer 2026\"). Omit for this year."
            }
          },
          required: ["plant"]
        }
      },
      %{
        name: "close_season",
        description:
          "Close out the season: archive EVERY active plant in the garden at once " <>
            "(\"close out the summer garden\"). Reports how many were retired.",
        parameters: %{
          type: "object",
          properties: %{
            season: %{
              type: "string",
              description:
                "Season label if the user names one (e.g. \"Summer 2026\"). Omit for this year."
            },
            for: %{
              type: "string",
              description:
                "Whose garden. Omit for the shared household garden (the default). " <>
                  "Use \"me\"/\"my\" for personal."
            }
          },
          required: []
        }
      },
      %{
        name: "remove_plant",
        description:
          "Delete a plant record entirely (a mistake — not a retirement; use archive_plant " <>
            "for plants that are done).",
        parameters: %{
          type: "object",
          properties: %{
            plant: %{type: "string", description: "Which plant to remove."}
          },
          required: ["plant"]
        }
      },
      %{
        name: "update_plant",
        description:
          "Change a plant's existing details IN PLACE (its name, species, location, count, or " <>
            "planted date) WITHOUT losing its notes/history. Use this to CORRECT or CHANGE a " <>
            "plant — never remove and re-add it. Matches by name or species; include ONLY the " <>
            "fields being changed.",
        parameters: %{
          type: "object",
          properties: %{
            plant: %{type: "string", description: "Which plant to edit, e.g. \"the tomatoes\"."},
            name: %{type: "string", description: "New name, only if changing it."},
            species: %{type: "string", description: "New species/variety, only if changing it."},
            location: %{type: "string", description: "New location, only if changing it."},
            count: %{type: "integer", description: "New count, only if changing it."},
            planted_on: %{
              type: "string",
              description: "New planting date as ISO (e.g. 2026-05-10), only if changing it."
            }
          },
          required: ["plant"]
        }
      }
    ]
  end

  @impl true
  def execute("add_plant", _args, %{user_id: nil}),
    do: {:ok, %{note: "no user session — plant not saved"}}

  def execute("add_plant", %{"name" => name} = args, ctx) do
    target = resolve_target(args["for"], ctx)

    attrs = %{
      name: name,
      species: args["species"],
      location: args["location"],
      count: args["count"],
      planted_on: parse_date(args["planted_on"])
    }

    case Garden.add_plant(target, attrs) do
      {:ok, plant} ->
        {:ok,
         %{
           plant: plant.name,
           species: plant.species,
           location: plant.location,
           count: plant.count,
           planted_on: iso(plant.planted_on),
           household: plant.household,
           assigned: target.assigned
         }}

      {:error, _} ->
        {:error, :invalid_plant}
    end
  end

  def execute("add_plant", _args, _ctx), do: {:error, :missing_args}

  def execute("note_plant", _args, %{user_id: nil}),
    do: {:ok, %{note: "no user session — note not saved"}}

  def execute("note_plant", %{"plant" => phrase, "note" => body} = args, ctx) do
    case Garden.find_plant(uid(ctx), phrase) do
      nil ->
        {:ok, %{note: "I don't see #{phrase} in the garden — nothing noted"}}

      plant ->
        {:ok, _note} = Garden.add_note(plant, body, parse_date(args["noted_on"]))
        {:ok, %{plant: plant.name, noted: body}}
    end
  end

  def execute("note_plant", _args, _ctx), do: {:error, :missing_args}

  def execute("list_garden", _args, %{user_id: nil}),
    do: {:ok, %{note: "no user session — nothing to read"}}

  def execute("list_garden", args, ctx) do
    %{active: active, archived_by_season: past} = Garden.garden(uid(ctx))

    result = %{active: Enum.map(active, &plant_map/1)}

    result =
      if args["include"] in ["archived", "past"] do
        Map.put(
          result,
          :past_seasons,
          Map.new(past, fn {season, plants} -> {season, Enum.map(plants, &plant_map/1)} end)
        )
      else
        result
      end

    if active == [] and result[:past_seasons] in [nil, %{}] do
      {:ok, Map.put(result, :note, "nothing growing yet")}
    else
      {:ok, result}
    end
  end

  def execute("archive_plant", _args, %{user_id: nil}),
    do: {:ok, %{note: "no user session — nothing to archive"}}

  def execute("archive_plant", %{"plant" => phrase} = args, ctx) do
    case Garden.find_plant(uid(ctx), phrase) do
      nil ->
        {:ok, %{note: "I don't see #{phrase} in the garden — nothing to archive"}}

      plant ->
        case Garden.archive_plant(plant, args["season"]) do
          {:ok, archived} -> {:ok, %{archived: archived.name, season: archived.season}}
          {:noop, noop} -> {:ok, %{note: "#{noop.name} is already archived"}}
        end
    end
  end

  def execute("archive_plant", _args, _ctx), do: {:error, :missing_args}

  def execute("close_season", _args, %{user_id: nil}),
    do: {:ok, %{note: "no user session — nothing to close out"}}

  def execute("close_season", args, ctx) do
    target = resolve_target(args["for"], ctx)

    case Garden.close_season(target, args["season"]) do
      0 -> {:ok, %{closed: 0, note: "nothing to close out"}}
      count -> {:ok, %{closed: count, assigned: target.assigned}}
    end
  end

  def execute("remove_plant", _args, %{user_id: nil}),
    do: {:ok, %{note: "no user session — nothing to remove"}}

  def execute("remove_plant", %{"plant" => phrase}, ctx) do
    case Garden.find_plant(uid(ctx), phrase) do
      nil ->
        {:ok, %{note: "I don't see #{phrase} in the garden — nothing to remove"}}

      plant ->
        {:ok, removed} = Garden.remove_plant(plant)
        {:ok, %{removed: removed.name}}
    end
  end

  def execute("remove_plant", _args, _ctx), do: {:error, :missing_args}

  def execute("update_plant", _args, %{user_id: nil}),
    do: {:ok, %{note: "no user session — nothing to update"}}

  def execute("update_plant", %{"plant" => phrase} = args, ctx) do
    case Garden.find_plant(uid(ctx), phrase) do
      nil ->
        {:ok, %{note: "I don't see #{phrase} in the garden — nothing to update"}}

      plant ->
        case update_attrs(args) do
          empty when empty == %{} ->
            {:ok, %{note: "nothing to change on #{plant.name}"}}

          attrs ->
            case Garden.update_plant(plant, attrs) do
              {:ok, updated} ->
                {:ok,
                 %{
                   plant: updated.name,
                   species: updated.species,
                   location: updated.location,
                   count: updated.count,
                   planted_on: iso(updated.planted_on),
                   household: updated.household
                 }}

              {:error, _} ->
                {:error, :invalid_plant}
            end
        end
    end
  end

  def execute("update_plant", _args, _ctx), do: {:error, :missing_args}

  # Build the edit from ONLY the fields the user actually mentioned, so changing (say) the planted
  # date never nulls out an unmentioned location/count.
  defp update_attrs(args) do
    %{}
    |> put_present(args, "name", :name, & &1)
    |> put_present(args, "species", :species, & &1)
    |> put_present(args, "location", :location, & &1)
    |> put_present(args, "count", :count, & &1)
    |> put_present(args, "planted_on", :planted_on, &parse_date/1)
  end

  defp put_present(acc, args, key, field, fun) do
    case Map.fetch(args, key) do
      {:ok, val} -> Map.put(acc, field, fun.(val))
      :error -> acc
    end
  end

  # notes are preloaded oldest-first, so the latest is the last.
  defp plant_map(plant) do
    %{
      name: plant.name,
      species: plant.species,
      location: plant.location,
      count: plant.count,
      planted_on: iso(plant.planted_on),
      season: plant.season,
      household: plant.household,
      latest_note: latest_note(plant)
    }
  end

  defp latest_note(%{notes: notes}) when is_list(notes) do
    case List.last(notes) do
      nil -> nil
      note -> note.body
    end
  end

  defp latest_note(_plant), do: nil

  # Lenient ISO-date parse: nil/""/unparseable -> nil (store what's given, require nothing).
  defp parse_date(nil), do: nil
  defp parse_date(""), do: nil

  defp parse_date(s) when is_binary(s) do
    case Date.from_iso8601(s) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp parse_date(_), do: nil

  defp iso(nil), do: nil
  defp iso(%Date{} = d), do: Date.to_iso8601(d)

  defp resolve_target(for_arg, ctx) do
    Target.resolve(for_arg, %{
      session_user_id: uid(ctx),
      gate_on: App.Config.default().kiosk_user_switch,
      users: Enum.filter(Users.list(), &Users.allowed?(&1.email))
    })
  end

  defp uid(%{user_id: uid}), do: uid
end
