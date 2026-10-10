defmodule App.CollectionsBroadcastTest do
  @moduledoc """
  The recipe book, trackers and routines tell subscribers when they change, so an open native
  Books panel re-renders whoever made the change — the brain mid-conversation, the other
  person, or the panel itself. Same shape as `App.Lists.broadcast_changed/2`: personal rows
  notify their owner's topic, household recipes notify the shared household topic.
  """
  use App.DataCase, async: false

  alias App.{Recipes, Routines, Trackers, Users}

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

  @lasagna %{
    title: "Lasagna",
    ingredients: ["1 lb ground beef", "12 lasagna noodles"],
    steps: ["Layer it up.", "Bake 25 minutes."]
  }

  defp sub(topic), do: Phoenix.PubSub.subscribe(App.PubSub, topic)

  describe "recipes" do
    test "saving a household recipe notifies the household topic, not the owner's", %{d: d} do
      sub("recipes:household")
      sub("recipes:#{d}")

      {:ok, _recipe, :created} = Recipes.save(d, @lasagna)

      assert_receive {:recipes_changed}
      refute_receive {:recipes_changed}, 50
    end

    test "saving a private recipe notifies only its owner's topic", %{d: d, t: t} do
      sub("recipes:household")
      sub("recipes:#{t}")

      {:ok, _recipe, :created} = Recipes.save(d, Map.put(@lasagna, :household, false))

      refute_receive {:recipes_changed}, 50

      Phoenix.PubSub.unsubscribe(App.PubSub, "recipes:#{t}")
      sub("recipes:#{d}")
      {:ok, _recipe, :replaced} = Recipes.save(d, Map.put(@lasagna, :household, false))
      assert_receive {:recipes_changed}
    end

    test "update and delete notify too", %{d: d} do
      {:ok, _recipe, :created} = Recipes.save(d, @lasagna)
      sub("recipes:household")

      {:ok, _updated, _report} = Recipes.update(d, "lasagna", %{add_note: "Rest it 10 minutes."})
      assert_receive {:recipes_changed}

      {:ok, _deleted} = Recipes.delete(d, "lasagna", :household)
      assert_receive {:recipes_changed}
    end

    test "a refused write notifies nobody", %{d: d} do
      sub("recipes:household")
      sub("recipes:#{d}")

      assert {:error, :missing_steps} = Recipes.save(d, Map.put(@lasagna, :steps, []))
      assert {:error, :not_found} = Recipes.delete(d, "nope")
      refute_receive {:recipes_changed}, 50
    end
  end

  describe "trackers" do
    test "log, delete_last and delete_tracker notify the owner's topic only", %{d: d, t: t} do
      sub("trackers:#{d}")
      sub("trackers:#{t}")

      {:ok, _} = Trackers.log(d, "headache", %{value: 6})
      assert_receive {:trackers_changed}

      {:ok, _tracker, _entry} = Trackers.delete_last(d, "headache")
      assert_receive {:trackers_changed}

      {:ok, _tracker, _count} = Trackers.delete_tracker(d, "headache")
      assert_receive {:trackers_changed}

      refute_receive {:trackers_changed}, 50
    end

    test "a refused write notifies nobody", %{d: d} do
      sub("trackers:#{d}")

      assert {:error, :invalid_name} = Trackers.log(d, "  ", %{})
      assert {:error, :not_found} = Trackers.delete_last(d, "nothing")
      refute_receive {:trackers_changed}, 50
    end
  end

  describe "routines" do
    test "save, mark_run and delete notify the owner's topic only", %{d: d, t: t} do
      sub("routines:#{d}")
      sub("routines:#{t}")

      {:ok, routine} = Routines.save(d, %{name: "Good night", steps: "Lights off."})
      assert_receive {:routines_changed}

      {:ok, _} = Routines.mark_run(routine)
      assert_receive {:routines_changed}

      {:ok, _} = Routines.delete(d, "good night")
      assert_receive {:routines_changed}

      refute_receive {:routines_changed}, 50
    end

    test "a refused write notifies nobody", %{d: d} do
      sub("routines:#{d}")

      assert {:error, :invalid_name} = Routines.save(d, %{name: " ", steps: "x"})
      assert {:error, :not_found} = Routines.delete(d, "nothing")
      refute_receive {:routines_changed}, 50
    end
  end
end
