defmodule App.Tools.GardenTest do
  use App.DataCase, async: false
  alias App.Tools.Garden, as: Tool
  alias App.Users

  setup do
    Application.put_env(:app, :allowed_users, [
      %{email: "d@x.com", name: "Alice"},
      %{email: "t@x.com", name: "Bob"}
    ])

    on_exit(fn -> Application.delete_env(:app, :allowed_users) end)
    {:ok, u} = Users.upsert_allowed("d@x.com")
    {:ok, other} = Users.upsert_allowed("t@x.com")
    %{user: u, other: other}
  end

  defp ctx(user),
    do: %{session_id: to_string(user.id), user_id: user.id, config: App.Config.default()}

  defp no_session, do: %{session_id: "default", user_id: nil, config: App.Config.default()}

  defp this_year, do: Integer.to_string(DateTime.utc_now().year)

  describe "add_plant" do
    test "only a name is needed; shared (household) by default", %{user: user} do
      assert {:ok, result} =
               Tool.execute("add_plant", %{"name" => "the tomatoes in the back"}, ctx(user))

      assert result.plant == "the tomatoes in the back"
      assert result.household == true
      assert result.assigned == "the household"

      assert [%{name: "the tomatoes in the back", status: "active"}] =
               App.Garden.garden(user.id).active
    end

    test "keeps the optional attrs and parses planted_on from an ISO string", %{user: user} do
      assert {:ok, result} =
               Tool.execute(
                 "add_plant",
                 %{
                   "name" => "tomatoes",
                   "species" => "Roma",
                   "location" => "back bed",
                   "count" => 5,
                   "planted_on" => "2026-07-11"
                 },
                 ctx(user)
               )

      assert result.planted_on == "2026-07-11"
      [plant] = App.Garden.garden(user.id).active
      assert plant.species == "Roma"
      assert plant.count == 5
      assert plant.planted_on == ~D[2026-07-11]
    end

    test "an unparseable planted_on is stored as nil (store what's given, require nothing)",
         %{user: user} do
      assert {:ok, result} =
               Tool.execute(
                 "add_plant",
                 %{"name" => "basil", "planted_on" => "last Tuesday"},
                 ctx(user)
               )

      assert result.planted_on == nil
    end

    test "for: my scopes it personal", %{user: user} do
      assert {:ok, result} =
               Tool.execute("add_plant", %{"name" => "my herbs", "for" => "my"}, ctx(user))

      assert result.household == false
      assert result.assigned == "you"
    end

    test "for: a named member assigns to them when kiosk_user_switch is on", %{
      user: user,
      other: other
    } do
      Application.put_env(:app, :kiosk_user_switch, true)
      on_exit(fn -> Application.delete_env(:app, :kiosk_user_switch) end)

      assert {:ok, result} =
               Tool.execute("add_plant", %{"name" => "bonsai", "for" => "bob"}, ctx(user))

      assert result.assigned == "Bob"
      assert [%{name: "bonsai"}] = App.Garden.garden(other.id).active
    end

    test "with no user session returns a narrated note" do
      assert {:ok, %{note: note}} = Tool.execute("add_plant", %{"name" => "basil"}, no_session())
      assert note =~ "no user session"
    end
  end

  describe "note_plant" do
    test "logs a check-in against a fuzzy name match", %{user: user} do
      {:ok, _} = Tool.execute("add_plant", %{"name" => "Cherry Tomatoes"}, ctx(user))

      assert {:ok, %{plant: "Cherry Tomatoes", noted: "looking leggy"}} =
               Tool.execute(
                 "note_plant",
                 %{"plant" => "tomatoes", "note" => "looking leggy"},
                 ctx(user)
               )

      [plant] = App.Garden.garden(user.id).active
      assert [%{body: "looking leggy"}] = plant.notes
    end

    test "matches on species too", %{user: user} do
      {:ok, _} =
        Tool.execute(
          "add_plant",
          %{"name" => "the red ones by the fence", "species" => "tomato"},
          ctx(user)
        )

      assert {:ok, %{plant: "the red ones by the fence"}} =
               Tool.execute("note_plant", %{"plant" => "tomato", "note" => "ripening"}, ctx(user))
    end

    test "no match returns a benign note", %{user: user} do
      assert {:ok, %{note: note}} =
               Tool.execute("note_plant", %{"plant" => "kale", "note" => "hm"}, ctx(user))

      assert note =~ "don't see"
    end

    test "with no user session returns a note" do
      assert {:ok, %{note: note}} =
               Tool.execute("note_plant", %{"plant" => "basil", "note" => "x"}, no_session())

      assert note =~ "no user session"
    end
  end

  describe "list_garden" do
    test "reads back the active plants with their latest note", %{user: user} do
      {:ok, _} =
        Tool.execute(
          "add_plant",
          %{"name" => "tomatoes", "location" => "back bed", "planted_on" => "2026-07-11"},
          ctx(user)
        )

      {:ok, _} =
        Tool.execute("note_plant", %{"plant" => "tomatoes", "note" => "sprouted"}, ctx(user))

      {:ok, _} =
        Tool.execute("note_plant", %{"plant" => "tomatoes", "note" => "leggy"}, ctx(user))

      assert {:ok, %{active: [plant]}} = Tool.execute("list_garden", %{}, ctx(user))
      assert plant.name == "tomatoes"
      assert plant.location == "back bed"
      assert plant.planted_on == "2026-07-11"
      assert plant.latest_note == "leggy"
    end

    test "include: archived also returns past seasons", %{user: user} do
      {:ok, _} = Tool.execute("add_plant", %{"name" => "basil"}, ctx(user))
      {:ok, _} = Tool.execute("archive_plant", %{"plant" => "basil"}, ctx(user))

      assert {:ok, result} = Tool.execute("list_garden", %{}, ctx(user))
      refute Map.has_key?(result, :past_seasons)

      assert {:ok, %{past_seasons: past}} =
               Tool.execute("list_garden", %{"include" => "archived"}, ctx(user))

      assert [%{name: "basil"}] = past[this_year()]
    end

    test "an empty garden reads back a benign note", %{user: user} do
      assert {:ok, %{active: [], note: note}} = Tool.execute("list_garden", %{}, ctx(user))
      assert note =~ "nothing growing yet"
    end

    test "with no user session returns a note" do
      assert {:ok, %{note: note}} = Tool.execute("list_garden", %{}, no_session())
      assert note =~ "no user session"
    end
  end

  describe "archive_plant" do
    test "archives a fuzzy match, stamping the default season (current year)", %{user: user} do
      {:ok, _} = Tool.execute("add_plant", %{"name" => "the basil on the windowsill"}, ctx(user))

      assert {:ok, %{archived: "the basil on the windowsill", season: season}} =
               Tool.execute("archive_plant", %{"plant" => "basil"}, ctx(user))

      assert season == this_year()
      assert App.Garden.garden(user.id).active == []
    end

    test "an explicit season is kept", %{user: user} do
      {:ok, _} = Tool.execute("add_plant", %{"name" => "basil"}, ctx(user))

      assert {:ok, %{season: "Summer 2026"}} =
               Tool.execute(
                 "archive_plant",
                 %{"plant" => "basil", "season" => "Summer 2026"},
                 ctx(user)
               )
    end

    test "an already-archived plant is a benign note", %{user: user} do
      {:ok, _} = Tool.execute("add_plant", %{"name" => "basil"}, ctx(user))
      {:ok, _} = Tool.execute("archive_plant", %{"plant" => "basil"}, ctx(user))

      assert {:ok, %{note: note}} =
               Tool.execute("archive_plant", %{"plant" => "basil"}, ctx(user))

      assert note =~ "already archived"
    end

    test "no match returns a benign note", %{user: user} do
      assert {:ok, %{note: note}} =
               Tool.execute("archive_plant", %{"plant" => "kale"}, ctx(user))

      assert note =~ "nothing to archive"
    end

    test "with no user session returns a note" do
      assert {:ok, %{note: note}} = Tool.execute("archive_plant", %{"plant" => "x"}, no_session())
      assert note =~ "no user session"
    end
  end

  describe "close_season" do
    test "sweeps all active household plants and reports the count", %{user: user} do
      {:ok, _} = Tool.execute("add_plant", %{"name" => "tomatoes"}, ctx(user))
      {:ok, _} = Tool.execute("add_plant", %{"name" => "peppers"}, ctx(user))

      assert {:ok, %{closed: 2, assigned: "the household"}} =
               Tool.execute("close_season", %{"season" => "Summer 2026"}, ctx(user))

      assert App.Garden.garden(user.id).active == []
    end

    test "nothing active -> 'nothing to close out'", %{user: user} do
      assert {:ok, %{closed: 0, note: note}} = Tool.execute("close_season", %{}, ctx(user))
      assert note =~ "nothing to close out"
    end

    test "with no user session returns a note" do
      assert {:ok, %{note: note}} = Tool.execute("close_season", %{}, no_session())
      assert note =~ "no user session"
    end
  end

  describe "remove_plant" do
    test "hard-deletes a fuzzy match", %{user: user} do
      {:ok, _} = Tool.execute("add_plant", %{"name" => "oops wrong plant"}, ctx(user))

      assert {:ok, %{removed: "oops wrong plant"}} =
               Tool.execute("remove_plant", %{"plant" => "oops"}, ctx(user))

      assert App.Garden.garden(user.id) == %{active: [], archived_by_season: %{}}
    end

    test "no match returns a benign note", %{user: user} do
      assert {:ok, %{note: note}} = Tool.execute("remove_plant", %{"plant" => "kale"}, ctx(user))
      assert note =~ "nothing to remove"
    end

    test "with no user session returns a note" do
      assert {:ok, %{note: note}} = Tool.execute("remove_plant", %{"plant" => "x"}, no_session())
      assert note =~ "no user session"
    end
  end

  test "declarations expose all six functions with only name required on add_plant" do
    decls = Tool.declarations()
    names = Enum.map(decls, & &1.name)

    assert Enum.sort(names) ==
             Enum.sort([
               "add_plant",
               "note_plant",
               "list_garden",
               "archive_plant",
               "close_season",
               "remove_plant"
             ])

    add = Enum.find(decls, &(&1.name == "add_plant"))
    assert add.parameters.required == ["name"]
  end
end
