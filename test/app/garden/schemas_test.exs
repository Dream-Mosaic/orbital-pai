defmodule App.Garden.SchemasTest do
  use ExUnit.Case, async: true
  alias App.Garden.{Plant, Note}

  describe "Plant.changeset/2" do
    test "valid with only user_id and name (nothing else required)" do
      cs = Plant.changeset(%Plant{}, %{user_id: 1, name: "the tomatoes I planted in the back"})
      assert cs.valid?
    end

    test "requires user_id and name" do
      cs = Plant.changeset(%Plant{}, %{})
      refute cs.valid?
      assert {"can't be blank", _} = cs.errors[:user_id]
      assert {"can't be blank", _} = cs.errors[:name]
    end

    test "casts the optional attrs, including an ISO date string for planted_on" do
      cs =
        Plant.changeset(%Plant{}, %{
          user_id: 1,
          name: "tomatoes",
          species: "Roma",
          location: "back bed",
          count: 5,
          planted_on: "2026-07-11"
        })

      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :planted_on) == ~D[2026-07-11]
      assert Ecto.Changeset.get_change(cs, :count) == 5
    end

    test "status defaults to active and only accepts active/archived" do
      assert %Plant{}.status == "active"

      cs = Plant.changeset(%Plant{}, %{user_id: 1, name: "basil", status: "dormant"})
      refute cs.valid?
      assert {"is invalid", _} = cs.errors[:status]

      cs = Plant.changeset(%Plant{}, %{user_id: 1, name: "basil", status: "archived"})
      assert cs.valid?
    end

    test "household defaults to false on the struct" do
      assert %Plant{}.household == false
    end
  end

  describe "Note.changeset/2" do
    test "valid with plant_id and body; noted_on optional" do
      cs = Note.changeset(%Note{}, %{plant_id: 1, body: "looking leggy"})
      assert cs.valid?
    end

    test "requires plant_id and body" do
      cs = Note.changeset(%Note{}, %{})
      refute cs.valid?
      assert {"can't be blank", _} = cs.errors[:plant_id]
      assert {"can't be blank", _} = cs.errors[:body]
    end

    test "casts an ISO date string for noted_on" do
      cs = Note.changeset(%Note{}, %{plant_id: 1, body: "watered", noted_on: "2026-07-11"})
      assert Ecto.Changeset.get_change(cs, :noted_on) == ~D[2026-07-11]
    end
  end
end
