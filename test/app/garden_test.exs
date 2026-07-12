defmodule App.GardenTest do
  use App.DataCase, async: false
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
end
