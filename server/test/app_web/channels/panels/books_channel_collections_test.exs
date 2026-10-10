defmodule AppWeb.Panels.BooksChannelCollectionsTest do
  @moduledoc """
  The Books panel's three collection books — recipes, trackers, routines — over the channel:
  the shelf, each body's scoping across two users, the two deletes and their scope rules, and
  the live re-push when anything else (the brain, the other person) changes them.
  """
  # async: false — SQLite is single-writer and these tests write.
  use AppWeb.ChannelCase, async: false

  alias App.{Lists, Recipes, Routines, Trackers, Users}

  setup do
    Application.put_env(:app, :allowed_users, [
      %{email: "alice@x.com", name: "Alice"},
      %{email: "bob@x.com", name: "Bob"}
    ])

    on_exit(fn -> Application.delete_env(:app, :allowed_users) end)
    {:ok, alice} = Users.upsert_allowed("alice@x.com")
    {:ok, bob} = Users.upsert_allowed("bob@x.com")
    token = AppWeb.UserAuth.socket_token(alice.id)
    {:ok, socket} = connect(AppWeb.UserSocket, %{"token" => token})
    %{socket: socket, alice: alice, bob: bob}
  end

  @lasagna %{
    title: "Lasagna",
    ingredients: ["1 lb ground beef", "12 noodles"],
    steps: ["Layer it up.", "Bake 25 minutes."]
  }

  defp recipe!(user, attrs) do
    {:ok, recipe, _} = Recipes.save(user.id, Map.merge(@lasagna, attrs))
    recipe
  end

  defp routine!(user, name, triggers \\ []) do
    {:ok, routine} =
      Routines.save(user.id, %{name: name, triggers: triggers, steps: "Lights off."})

    routine
  end

  defp pick!(user, key) do
    {:ok, u} = Users.update_prefs(user, %{books_last_book: key})
    u
  end

  # Opens Alice's panel on `key` and returns the socket and the first state.
  defp open!(socket, alice, key) do
    pick!(alice, key)
    {:ok, _reply, sock} = subscribe_and_join(socket, "panel:books:#{alice.id}", %{})
    assert_push "state", state
    {sock, state}
  end

  # See books_channel_test.exs's drain!/1: block until every in-flight re-push is handled, so
  # the channel is never killed mid-query when the test returns.
  defp drain!(sock) do
    ref = push(sock, "__test_drain__", %{})
    assert_reply ref, :error, %{reason: "bad_request"}
  end

  describe "the shelf" do
    test "recipes, trackers and routines follow the garden, with bare icon names",
         %{socket: socket, alice: alice} do
      Lists.find_or_create_list(%{user_id: alice.id, household: false}, "Apples")

      {sock, state} = open!(socket, alice, nil)

      assert Enum.map(state.books, & &1.label) ==
               ["Apples", "Garden", "Recipes", "Trackers", "Routines"]

      assert Enum.map(state.books, & &1.kind) ==
               ["list", "garden", "recipes", "trackers", "routines"]

      assert Enum.map(Enum.drop(state.books, 2), & &1.icon) == ["cake", "chart-bar", "bolt"]
      # Not current: no collection body rides along.
      assert %{recipes: nil, trackers: nil, routines: nil} = state
      drain!(sock)
    end

    test "select_book on a collection persists it, pushes it, and offers no Clear",
         %{socket: socket, alice: alice} do
      {sock, _} = open!(socket, alice, nil)

      ref = push(sock, "select_book", %{"key" => "recipes"})
      assert_reply ref, :ok

      assert_push "state", %{current_key: "recipes", clear_confirm: nil} = state
      assert %{items: [], empty: "No recipes yet."} = state.recipes
      assert %{list: nil, garden: nil, trackers: nil, routines: nil} = state
      assert Users.get(alice.id).books_last_book == "recipes"
      drain!(sock)
    end

    test "a remembered collection is current on join", %{socket: socket, alice: alice} do
      {sock, state} = open!(socket, alice, "routines")
      assert state.current_key == "routines"
      assert state.routines.items == []
      drain!(sock)
    end

    test "clear_book on a collection is refused and touches nothing",
         %{socket: socket, alice: alice} do
      recipe!(alice, %{})
      {sock, _} = open!(socket, alice, "recipes")

      ref = push(sock, "clear_book", %{"key" => "recipes"})
      assert_reply ref, :error, %{reason: "bad_request"}
      assert [_] = Recipes.list(alice.id)
      drain!(sock)
    end
  end

  describe "recipes" do
    test "Alice sees household recipes (whoever saved them) and her own, never Bob's private ones",
         %{socket: socket, alice: alice, bob: bob} do
      recipe!(bob, %{title: "Chili"})
      recipe!(bob, %{title: "Secret Salsa", household: false})
      recipe!(alice, %{title: "Lasagna", household: false, servings: "6"})

      {sock, state} = open!(socket, alice, "recipes")

      assert Enum.map(state.recipes.items, &{&1.title, &1.tag}) ==
               [{"Chili", "shared"}, {"Lasagna", "yours"}]

      lasagna = Enum.find(state.recipes.items, &(&1.title == "Lasagna"))
      assert lasagna.meta == "2 ingredients · 2 steps"
      assert lasagna.detail_meta == "Serves 6"
      assert lasagna.ingredients == ["1 lb ground beef", "12 noodles"]
      assert lasagna.steps == ["Layer it up.", "Bake 25 minutes."]
      assert lasagna.delete_confirm == "Delete your recipe “Lasagna”? This can't be undone."
      drain!(sock)
    end

    test "delete_recipe deletes a household recipe someone else saved — it's shared",
         %{socket: socket, alice: alice, bob: bob} do
      chili = recipe!(bob, %{title: "Chili"})
      {sock, _} = open!(socket, alice, "recipes")

      ref = push(sock, "delete_recipe", %{"id" => chili.id})
      assert_reply ref, :ok

      # The context's broadcast re-pushes; the channel does not push for itself.
      assert_push "state", %{recipes: %{items: []}}
      assert Recipes.list(bob.id) == []
      drain!(sock)
    end

    test "delete_recipe passes the item's OWN scope: the private variant goes, the shared stays",
         %{socket: socket, alice: alice} do
      shared = recipe!(alice, %{title: "Lasagna"})
      mine = recipe!(alice, %{title: "Lasagna", household: false})
      {sock, state} = open!(socket, alice, "recipes")
      assert length(state.recipes.items) == 2

      ref = push(sock, "delete_recipe", %{"id" => mine.id})
      assert_reply ref, :ok
      assert_push "state", %{recipes: %{items: [%{id: id, tag: "shared"}]}}
      assert id == shared.id

      assert [%{id: ^id}] = Recipes.list(alice.id)
      drain!(sock)
    end

    test "…and the other way round: the shared one goes, the private variant stays",
         %{socket: socket, alice: alice} do
      shared = recipe!(alice, %{title: "Lasagna"})
      mine = recipe!(alice, %{title: "Lasagna", household: false})
      {sock, _} = open!(socket, alice, "recipes")

      ref = push(sock, "delete_recipe", %{"id" => shared.id})
      assert_reply ref, :ok
      assert_push "state", %{recipes: %{items: [%{tag: "yours"}]}}

      assert [%{id: id}] = Recipes.list(alice.id)
      assert id == mine.id
      drain!(sock)
    end

    test "delete_recipe refuses Bob's private recipe and an unknown id",
         %{socket: socket, alice: alice, bob: bob} do
      secret = recipe!(bob, %{title: "Secret Salsa", household: false})
      {sock, _} = open!(socket, alice, "recipes")

      ref = push(sock, "delete_recipe", %{"id" => secret.id})
      assert_reply ref, :error, %{reason: "bad_request"}

      ref = push(sock, "delete_recipe", %{"id" => 999_999})
      assert_reply ref, :error, %{reason: "bad_request"}

      ref = push(sock, "delete_recipe", %{"id" => "nope"})
      assert_reply ref, :error, %{reason: "bad_request"}

      assert [_] = Recipes.list(bob.id)
      refute_push "state", %{}, 100
      drain!(sock)
    end

    test "a household recipe saved by the OTHER person re-pushes live",
         %{socket: socket, alice: alice, bob: bob} do
      {sock, state} = open!(socket, alice, "recipes")
      assert state.recipes.items == []

      recipe!(bob, %{title: "Chili"})

      assert_push "state", %{recipes: %{items: [%{title: "Chili"}]}}
      drain!(sock)
    end

    test "the other person's PRIVATE recipe does not reach Alice's panel at all",
         %{socket: socket, alice: alice, bob: bob} do
      {sock, _} = open!(socket, alice, "recipes")

      recipe!(bob, %{title: "Secret Salsa", household: false})

      refute_push "state", %{}, 100
      drain!(sock)
    end
  end

  describe "trackers" do
    test "only Alice's own trackers, with the list row and the detail",
         %{socket: socket, alice: alice, bob: bob} do
      {:ok, _} = Trackers.log(alice.id, "headaches", %{value: 6, tags: ["skipped lunch"]})
      {:ok, _} = Trackers.log(bob.id, "back pain", %{value: 3})

      {sock, state} = open!(socket, alice, "trackers")

      assert [t] = state.trackers.items
      assert t.label == "Headaches"
      assert t.count == "1 entry"
      assert t.last == "Today · 6"
      assert length(t.series) == 30
      assert List.last(t.series).count == 1
      assert [%{label: "Average", value: "6"} | _] = t.stats
      assert t.tags == [%{tag: "skipped lunch", tally: nil}]
      assert [%{day: "Today", value: "6", tags: ["skipped lunch"]}] = t.recent
      drain!(sock)
    end

    test "a voice log re-pushes live; the other person's does not",
         %{socket: socket, alice: alice, bob: bob} do
      {sock, state} = open!(socket, alice, "trackers")
      assert state.trackers.items == []

      {:ok, _} = Trackers.log(bob.id, "back pain", %{value: 3})
      refute_push "state", %{}, 100

      {:ok, _} = Trackers.log(alice.id, "headache", %{value: 4})
      assert_push "state", %{trackers: %{items: [%{label: "Headache", last: "Today · 4"}]}}
      drain!(sock)
    end

    test "there is no tracker delete on the panel", %{socket: socket, alice: alice} do
      {:ok, %{tracker: t}} = Trackers.log(alice.id, "headache", %{value: 4})
      {sock, _} = open!(socket, alice, "trackers")

      ref = push(sock, "delete_tracker", %{"id" => t.id})
      assert_reply ref, :error, %{reason: "bad_request"}
      assert [_] = Trackers.list(alice.id)
      drain!(sock)
    end
  end

  describe "routines" do
    test "only Alice's own routines, with what to say and the steps",
         %{socket: socket, alice: alice, bob: bob} do
      routine!(alice, "Good night", ["bedtime"])
      routine!(bob, "Movie time")

      {sock, state} = open!(socket, alice, "routines")

      assert [r] = state.routines.items
      assert r.name == "Good night"
      assert r.say == ["Good night", "bedtime"]
      assert r.steps == "Lights off."
      assert r.last_run == "Not run yet"
      drain!(sock)
    end

    test "delete_routine deletes Alice's own routine and re-pushes",
         %{socket: socket, alice: alice} do
      night = routine!(alice, "Good night")
      routine!(alice, "Morning")
      {sock, _} = open!(socket, alice, "routines")

      ref = push(sock, "delete_routine", %{"id" => night.id})
      assert_reply ref, :ok
      assert_push "state", %{routines: %{items: [%{name: "Morning"}]}}
      assert Enum.map(Routines.list(alice.id), & &1.label) == ["Morning"]
      drain!(sock)
    end

    test "delete_routine refuses Bob's routine", %{socket: socket, alice: alice, bob: bob} do
      movie = routine!(bob, "Movie time")
      {sock, _} = open!(socket, alice, "routines")

      ref = push(sock, "delete_routine", %{"id" => movie.id})
      assert_reply ref, :error, %{reason: "bad_request"}
      assert [_] = Routines.list(bob.id)
      drain!(sock)
    end

    test "a routine saved or run by voice re-pushes live", %{socket: socket, alice: alice} do
      {sock, _} = open!(socket, alice, "routines")

      night = routine!(alice, "Good night")
      assert_push "state", %{routines: %{items: [%{last_run: "Not run yet"}]}}

      {:ok, _} = Routines.mark_run(night)
      assert_push "state", %{routines: %{items: [%{last_run: "Ran today, " <> _}]}}
      drain!(sock)
    end
  end
end
