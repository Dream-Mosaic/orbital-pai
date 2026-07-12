defmodule App.GardenTest do
  use App.DataCase, async: false
  alias App.Garden
  alias App.Garden.{Plant, Note}
  alias App.Users

  setup do
    Application.put_env(:app, :allowed_users, [
      %{email: "d@x.com", name: "Alice"},
      %{email: "t@x.com", name: "Bob"}
    ])

    on_exit(fn -> Application.delete_env(:app, :allowed_users) end)
    {:ok, d} = Users.upsert_allowed("d@x.com")
    {:ok, t} = Users.upsert_allowed("t@x.com")
    %{d: d.id, t: t.id}
  end

  describe "schema round-trip" do
    test "a plant persists with defaults: status active, household false, optional fields nil",
         %{d: d} do
      {:ok, plant} =
        %Plant{} |> Plant.changeset(%{user_id: d, name: "tomatoes"}) |> Repo.insert()

      assert plant.status == "active"
      assert plant.household == false
      assert plant.species == nil
      assert plant.planted_on == nil
      assert plant.season == nil
      assert plant.archived_at == nil
    end

    test "a plant keeps its optional attrs", %{d: d} do
      {:ok, plant} =
        %Plant{}
        |> Plant.changeset(%{
          user_id: d,
          name: "tomatoes",
          species: "Roma",
          location: "back bed",
          count: 5,
          planted_on: ~D[2026-07-11],
          household: true
        })
        |> Repo.insert()

      assert plant.count == 5
      assert plant.planted_on == ~D[2026-07-11]
      assert plant.household == true
    end

    test "a note persists under a plant; noted_on defaults nil", %{d: d} do
      {:ok, plant} = %Plant{} |> Plant.changeset(%{user_id: d, name: "basil"}) |> Repo.insert()

      {:ok, note} =
        %Note{} |> Note.changeset(%{plant_id: plant.id, body: "bolted"}) |> Repo.insert()

      assert note.body == "bolted"
      assert note.noted_on == nil
    end

    test "deleting a plant deletes its notes (FK cascade)", %{d: d} do
      {:ok, plant} = %Plant{} |> Plant.changeset(%{user_id: d, name: "basil"}) |> Repo.insert()

      {:ok, note} =
        %Note{} |> Note.changeset(%{plant_id: plant.id, body: "bolted"}) |> Repo.insert()

      Repo.delete!(plant)
      assert Repo.get(Note, note.id) == nil
    end
  end

  describe "add_plant/2" do
    test "creates an active plant for the resolved owner with only a name", %{d: d} do
      assert {:ok, plant} =
               Garden.add_plant(%{user_id: d, household: true}, %{
                 name: "the tomatoes in the back"
               })

      assert plant.name == "the tomatoes in the back"
      assert plant.status == "active"
      assert plant.household == true
      assert plant.user_id == d
    end

    test "keeps whatever optional attrs were supplied", %{d: d} do
      {:ok, plant} =
        Garden.add_plant(%{user_id: d, household: false}, %{
          name: "tomatoes",
          species: "Roma",
          location: "back bed",
          count: 5,
          planted_on: ~D[2026-07-11]
        })

      assert plant.species == "Roma"
      assert plant.count == 5
      assert plant.planted_on == ~D[2026-07-11]
      assert plant.household == false
    end

    test "requires a name", %{d: d} do
      assert {:error, cs} = Garden.add_plant(%{user_id: d, household: true}, %{})
      assert %{name: ["can't be blank"]} = errors_on(cs)
    end

    test "broadcasts on the owner topic; household rows also on garden:household", %{d: d} do
      Phoenix.PubSub.subscribe(App.PubSub, "garden:#{d}")
      Phoenix.PubSub.subscribe(App.PubSub, "garden:household")

      {:ok, _} = Garden.add_plant(%{user_id: d, household: true}, %{name: "basil"})
      assert_receive {:garden_changed}
      assert_receive {:garden_changed}
    end

    test "a personal plant does NOT notify garden:household", %{d: d} do
      Phoenix.PubSub.subscribe(App.PubSub, "garden:household")
      {:ok, _} = Garden.add_plant(%{user_id: d, household: false}, %{name: "basil"})
      refute_receive {:garden_changed}, 100
    end
  end

  describe "garden/1" do
    test "returns own + household plants, not other users' personal ones", %{d: d, t: t} do
      {:ok, _mine} = Garden.add_plant(%{user_id: d, household: false}, %{name: "my herbs"})
      {:ok, _shared} = Garden.add_plant(%{user_id: t, household: true}, %{name: "tomatoes"})
      {:ok, _theirs} = Garden.add_plant(%{user_id: t, household: false}, %{name: "bonsai"})

      names = Garden.garden(d).active |> Enum.map(& &1.name) |> Enum.sort()
      assert names == ["my herbs", "tomatoes"]
    end

    test "splits active from archived, grouping archived by season", %{d: d} do
      {:ok, active} = Garden.add_plant(%{user_id: d, household: true}, %{name: "peppers"})
      {:ok, done} = Garden.add_plant(%{user_id: d, household: true}, %{name: "basil"})
      {:ok, _} = Garden.archive_plant(done, "Summer 2026")

      g = Garden.garden(d)
      assert Enum.map(g.active, & &1.id) == [active.id]
      assert [%{name: "basil"}] = g.archived_by_season["Summer 2026"]
    end

    test "a nil season falls back to the year of archived_at", %{d: d} do
      {:ok, plant} = Garden.add_plant(%{user_id: d, household: true}, %{name: "basil"})

      {:ok, archived} =
        plant
        |> App.Garden.Plant.changeset(%{
          status: "archived",
          archived_at: ~U[2025-10-01 12:00:00Z]
        })
        |> Repo.update()

      assert Garden.season_of(archived) == "2025"
      g = Garden.garden(d)
      assert [%{name: "basil"}] = g.archived_by_season["2025"]
    end

    test "plants come with their notes preloaded, oldest first", %{d: d} do
      {:ok, plant} = Garden.add_plant(%{user_id: d, household: true}, %{name: "tomatoes"})
      {:ok, _} = Garden.add_note(plant, "sprouted")
      {:ok, _} = Garden.add_note(plant, "first true leaves")

      [loaded] = Garden.garden(d).active
      assert Enum.map(loaded.notes, & &1.body) == ["sprouted", "first true leaves"]
    end

    test "an empty garden is %{active: [], archived_by_season: %{}}", %{d: d} do
      assert Garden.garden(d) == %{active: [], archived_by_season: %{}}
    end
  end

  describe "find_plant/2" do
    test "matches a phrase against the name, case-insensitive contains either way", %{d: d} do
      {:ok, plant} =
        Garden.add_plant(%{user_id: d, household: true}, %{name: "Cherry Tomatoes"})

      assert Garden.find_plant(d, "tomatoes").id == plant.id
      assert Garden.find_plant(d, "the cherry tomatoes out back").id == plant.id
    end

    test "matches on species too", %{d: d} do
      {:ok, plant} =
        Garden.add_plant(%{user_id: d, household: true}, %{
          name: "the red ones by the fence",
          species: "tomato"
        })

      assert Garden.find_plant(d, "tomato").id == plant.id
    end

    test "an ACTIVE plant wins over an archived namesake", %{d: d} do
      {:ok, old} = Garden.add_plant(%{user_id: d, household: true}, %{name: "tomatoes"})
      {:ok, _} = Garden.archive_plant(old, "2025")
      {:ok, fresh} = Garden.add_plant(%{user_id: d, household: true}, %{name: "tomatoes"})

      assert Garden.find_plant(d, "tomatoes").id == fresh.id
    end

    test "searches the visible set only (own + household)", %{d: d, t: t} do
      {:ok, _theirs} = Garden.add_plant(%{user_id: t, household: false}, %{name: "bonsai"})
      assert Garden.find_plant(d, "bonsai") == nil
    end

    test "nil for no match and for a blank phrase", %{d: d} do
      {:ok, _} = Garden.add_plant(%{user_id: d, household: true}, %{name: "basil"})
      assert Garden.find_plant(d, "nonexistent") == nil
      assert Garden.find_plant(d, "") == nil
    end
  end

  describe "archive_plant/2" do
    test "stamps archived_at and a default season = the current year, and broadcasts", %{d: d} do
      {:ok, plant} = Garden.add_plant(%{user_id: d, household: true}, %{name: "basil"})
      Phoenix.PubSub.subscribe(App.PubSub, "garden:household")

      assert {:ok, archived} = Garden.archive_plant(plant)
      assert archived.status == "archived"
      assert archived.archived_at != nil
      assert archived.season == Integer.to_string(DateTime.utc_now().year)
      assert_receive {:garden_changed}
    end

    test "an explicit season is kept verbatim", %{d: d} do
      {:ok, plant} = Garden.add_plant(%{user_id: d, household: true}, %{name: "basil"})
      {:ok, archived} = Garden.archive_plant(plant, "Summer 2026")
      assert archived.season == "Summer 2026"
    end

    test "archiving an already-archived plant is a benign no-op", %{d: d} do
      {:ok, plant} = Garden.add_plant(%{user_id: d, household: true}, %{name: "basil"})
      {:ok, archived} = Garden.archive_plant(plant, "2025")

      assert {:noop, ^archived} = Garden.archive_plant(archived)
      assert Repo.get!(Plant, archived.id).season == "2025"
    end
  end

  describe "close_season/2" do
    test "bulk-archives every ACTIVE plant in the owner scope and returns the count", %{d: d} do
      {:ok, _} = Garden.add_plant(%{user_id: d, household: true}, %{name: "tomatoes"})
      {:ok, _} = Garden.add_plant(%{user_id: d, household: true}, %{name: "peppers"})
      {:ok, old} = Garden.add_plant(%{user_id: d, household: true}, %{name: "basil"})
      {:ok, _} = Garden.archive_plant(old, "2025")

      assert Garden.close_season(%{user_id: d, household: true}, "Summer 2026") == 2

      g = Garden.garden(d)
      assert g.active == []
      # the pre-archived plant kept its own season
      assert Enum.map(g.archived_by_season["2025"], & &1.name) == ["basil"]

      assert g.archived_by_season["Summer 2026"] |> Enum.map(& &1.name) |> Enum.sort() ==
               ["peppers", "tomatoes"]
    end

    test "a personal close-out does not touch household plants (and vice versa)", %{d: d} do
      {:ok, _} = Garden.add_plant(%{user_id: d, household: true}, %{name: "tomatoes"})
      {:ok, _} = Garden.add_plant(%{user_id: d, household: false}, %{name: "my herbs"})

      assert Garden.close_season(%{user_id: d, household: false}) == 1
      assert Enum.map(Garden.garden(d).active, & &1.name) == ["tomatoes"]
    end

    test "nothing active -> 0", %{d: d} do
      assert Garden.close_season(%{user_id: d, household: true}) == 0
    end

    test "defaults the season to the current year and broadcasts once", %{d: d} do
      {:ok, _} = Garden.add_plant(%{user_id: d, household: true}, %{name: "tomatoes"})
      Phoenix.PubSub.subscribe(App.PubSub, "garden:#{d}")

      assert Garden.close_season(%{user_id: d, household: true}) == 1
      assert_receive {:garden_changed}
      refute_receive {:garden_changed}, 100

      year = Integer.to_string(DateTime.utc_now().year)
      assert [_] = Garden.garden(d).archived_by_season[year]
    end
  end

  describe "add_note/3" do
    test "appends a check-in note and broadcasts", %{d: d} do
      {:ok, plant} = Garden.add_plant(%{user_id: d, household: true}, %{name: "tomatoes"})
      Phoenix.PubSub.subscribe(App.PubSub, "garden:#{d}")

      assert {:ok, note} = Garden.add_note(plant, "looking leggy")
      assert note.body == "looking leggy"
      assert note.noted_on == nil
      assert_receive {:garden_changed}
    end

    test "keeps an explicit noted_on date", %{d: d} do
      {:ok, plant} = Garden.add_plant(%{user_id: d, household: false}, %{name: "basil"})
      {:ok, note} = Garden.add_note(plant, "bolted", ~D[2026-07-10])
      assert note.noted_on == ~D[2026-07-10]
    end
  end

  describe "revive_plant/1, rename_plant/2, remove_plant/1" do
    test "revive returns an archived plant to active and clears season/archived_at", %{d: d} do
      {:ok, plant} = Garden.add_plant(%{user_id: d, household: true}, %{name: "basil"})
      {:ok, archived} = Garden.archive_plant(plant, "2025")

      assert {:ok, revived} = Garden.revive_plant(archived)
      assert revived.status == "active"
      assert revived.season == nil
      assert revived.archived_at == nil
    end

    test "rename changes the name and broadcasts", %{d: d} do
      {:ok, plant} = Garden.add_plant(%{user_id: d, household: true}, %{name: "the red ones"})
      Phoenix.PubSub.subscribe(App.PubSub, "garden:#{d}")

      assert {:ok, renamed} = Garden.rename_plant(plant, "cherry tomatoes")
      assert renamed.name == "cherry tomatoes"
      assert_receive {:garden_changed}
    end

    test "remove hard-deletes the plant and its notes (cascade)", %{d: d} do
      {:ok, plant} = Garden.add_plant(%{user_id: d, household: true}, %{name: "oops"})
      {:ok, note} = Garden.add_note(plant, "wrong plant")

      assert {:ok, _} = Garden.remove_plant(plant)
      assert Repo.get(Plant, plant.id) == nil
      assert Repo.get(Note, note.id) == nil
    end
  end
end
