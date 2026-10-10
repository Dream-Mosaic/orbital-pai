defmodule App.RoutinesTest do
  use App.DataCase, async: false
  alias App.Routines
  alias App.Routines.Routine
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

  defp good_night(extra \\ %{}) do
    Map.merge(
      %{
        name: "Good night",
        triggers: ["good night", "bedtime"],
        steps: "Turn off the downstairs lights. Set the thermostat to 68."
      },
      extra
    )
  end

  describe "save/2" do
    test "creates a routine keeping the label as said and a normalized name", %{d: d} do
      assert {:ok, %Routine{} = r} = Routines.save(d, good_night())

      assert r.label == "Good night"
      assert r.name == "goodnight"
      assert r.triggers == ["good night", "bedtime"]
      assert r.steps =~ "thermostat to 68"
      assert r.last_run_at == nil
      assert r.user_id == d
    end

    test "saving the same name again (any casing/punctuation) REPLACES it", %{d: d} do
      {:ok, first} = Routines.save(d, good_night())

      {:ok, second} =
        Routines.save(d, %{name: "good-night!", triggers: ["lights out"], steps: "Lock up."})

      assert second.id == first.id
      assert second.label == "good-night!"
      assert second.triggers == ["lights out"]
      assert second.steps == "Lock up."
      assert [_one] = Routines.list(d)
    end

    test "triggers are trimmed, de-duplicated, and blanks dropped", %{d: d} do
      {:ok, r} =
        Routines.save(
          d,
          good_night(%{triggers: [" bedtime ", "Bedtime!", "", "  ", "lights out"]})
        )

      assert r.triggers == ["bedtime", "lights out"]
    end

    test "missing triggers is fine — the name itself is a trigger", %{d: d} do
      {:ok, r} = Routines.save(d, %{name: "leaving", steps: "Turn off every light."})
      assert r.triggers == []
    end

    test "a blank name or blank steps is invalid", %{d: d} do
      assert {:error, :invalid_name} = Routines.save(d, good_night(%{name: "  !! "}))
      assert {:error, %Ecto.Changeset{}} = Routines.save(d, good_night(%{steps: "   "}))
    end

    test "steps over 2,000 chars are rejected", %{d: d} do
      assert {:error, %Ecto.Changeset{} = cs} =
               Routines.save(d, good_night(%{steps: String.duplicate("a", 2_001)}))

      assert %{steps: [_]} = errors_on(cs)
      assert {:ok, _} = Routines.save(d, good_night(%{steps: String.duplicate("a", 2_000)}))
    end

    test "a trigger another routine already answers to is refused, naming that routine",
         %{d: d} do
      {:ok, _} = Routines.save(d, good_night())

      assert {:error, {:trigger_taken, "Bedtime", "Good night"}} =
               Routines.save(d, %{name: "kids down", triggers: ["Bedtime"], steps: "Dim lights."})

      # the other routine's NAME counts as a trigger too
      assert {:error, {:trigger_taken, "goodnight", "Good night"}} =
               Routines.save(d, %{name: "sleepy", triggers: ["goodnight"], steps: "Dim lights."})
    end

    test "another user's triggers never conflict", %{d: d, t: t} do
      {:ok, _} = Routines.save(d, good_night())
      assert {:ok, _} = Routines.save(t, good_night())
    end
  end

  describe "get/2" do
    setup %{d: d} do
      {:ok, _} = Routines.save(d, good_night())

      {:ok, _} =
        Routines.save(d, %{name: "Leaving", triggers: ["I'm heading out"], steps: "Lights off."})

      :ok
    end

    test "matches the name, case- and punctuation-insensitively", %{d: d} do
      assert %Routine{label: "Good night"} = Routines.get(d, "good night")
      assert %Routine{label: "Good night"} = Routines.get(d, "GOOD NIGHT!")
      assert %Routine{label: "Good night"} = Routines.get(d, "goodnight")
      assert %Routine{label: "Good night"} = Routines.get(d, "my good-night routine")
    end

    test "matches any trigger the same way", %{d: d} do
      assert %Routine{label: "Good night"} = Routines.get(d, "Bedtime.")
      assert %Routine{label: "Leaving"} = Routines.get(d, "im heading out")
      assert %Routine{label: "Leaving"} = Routines.get(d, "I’m heading out!")
    end

    test "no match, blank or non-string -> nil", %{d: d} do
      assert Routines.get(d, "good morning") == nil
      assert Routines.get(d, "  ") == nil
      assert Routines.get(d, nil) == nil
    end

    test "is per-user: another user's routine is invisible", %{t: t} do
      assert Routines.get(t, "good night") == nil
    end
  end

  test "list/1 returns only the user's routines, alphabetical by label", %{d: d, t: t} do
    {:ok, _} = Routines.save(d, %{name: "Leaving", steps: "Lights off."})
    {:ok, _} = Routines.save(d, good_night())
    {:ok, _} = Routines.save(t, %{name: "Morning", steps: "Read the weather."})

    assert ["Good night", "Leaving"] = d |> Routines.list() |> Enum.map(& &1.label)
    assert ["Morning"] = t |> Routines.list() |> Enum.map(& &1.label)
  end

  test "brief/1 is name + triggers only (no steps) for the brain prompt", %{d: d} do
    {:ok, _} = Routines.save(d, good_night())

    assert Routines.brief(d) == [%{name: "Good night", triggers: ["good night", "bedtime"]}]
    assert Routines.brief(-1) == []
  end

  describe "delete/2" do
    test "deletes by name or trigger, case-insensitively", %{d: d} do
      {:ok, _} = Routines.save(d, good_night())
      assert {:ok, %Routine{label: "Good night"}} = Routines.delete(d, "BEDTIME")
      assert Routines.list(d) == []
    end

    test "unknown -> :not_found, and never another user's routine", %{d: d, t: t} do
      {:ok, _} = Routines.save(d, good_night())
      assert {:error, :not_found} = Routines.delete(t, "good night")
      assert {:error, :not_found} = Routines.delete(d, "good morning")
      assert [_] = Routines.list(d)
    end
  end

  test "mark_run/1 stamps last_run_at", %{d: d} do
    {:ok, r} = Routines.save(d, good_night())
    assert {:ok, ran} = Routines.mark_run(r)
    assert %DateTime{} = ran.last_run_at
    assert Routines.get(d, "good night").last_run_at == ran.last_run_at
  end

  test "routines are deleted with their user", %{d: d} do
    {:ok, _} = Routines.save(d, good_night())
    Repo.delete!(Users.get(d))
    assert Repo.all(Routine) == []
  end
end
