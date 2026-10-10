defmodule AppWeb.Panels.BooksChannel do
  @moduledoc """
  The native Books drawer's data path — a bottom-nav station like Reminders and
  Connectors. Joined only while the drawer is on screen: join MEANS open.

  Non-essential: a refusal stops this channel and leaves the conversation alone.

  ## This channel is HYBRID, and that is the whole trap

  Ten of its twelve writes broadcast: eight go through `App.Lists`/`App.Garden`,
  two through `App.Recipes`/`App.Routines` (see "The collections" below). So
  this channel RIDES them: it subscribes to their topics in `join/2` and
  re-pushes on `{:lists_changed}`/`{:garden_changed}`. A change from ANY source
  — this panel, the web LiveView, a voice tool, the scheduler — reaches an open
  drawer with no refresh.

  TWO writes do not broadcast, and each was READ before this file was written:

    * `App.Users.update_prefs/2` (`users.ex:86-88`) — a bare `Repo.update`.
      This is what `select_book` writes.
    * `App.Lists.find_or_create_list/2` (`lists.ex:19-43`) — the ONLY mutating
      function in `App.Lists` with no `broadcast_changed/2`. Compare every other
      write in that file. The web survives it because `new_list`'s handler calls
      `load_lists() |> load_books()` itself (`conversation_live.ex:266-269`).

  So `select_book` and `new_list` push `state` THEMSELVES; the other ten must
  not. Ride them uniformly and creating a list silently freezes the panel — the
  write lands, the reply is `:ok`, and nothing on screen changes. That is the
  Phase-2 Memory failure exactly, and DB-level tests pass straight through it.
  Read `lists.ex` before adding or removing one of those pushes.

  ## Duplicate pushes are expected

  A household row broadcasts on both `lists:<uid>` and `lists:household`
  (`lists.ex:172-175`) and this channel subscribes to both, so a user acting on
  their own household list gets two pushes for one write. `clear_book` on the
  garden gets THREE — `Books.clear/1` calls `close_season/2` twice
  (`books.ex:101-105`) and the household call broadcasts on two topics. Each
  push carries the same, now-current state. Left un-deduplicated on purpose,
  like `RemindersChannel`.

  ## Three queries, and the nudge that follows from them

  `state/1`'s own `Books.for_user/1` call (`books.ex:34`) is the first
  `Lists.list_visible/1`. `Books.current/1` (`books.ex:94`) — the shared
  resolution rule this channel and the web LiveView both call, see below — does
  its own `for_user/1` rather than reuse the one `state/1` already computed,
  because its OTHER caller (`clear_book`) never needs the full list at all.
  That is the second. `list_body/2` then does its own `Lists.list_visible/1`
  lookup for the current book's actual list struct (with items) — the third.
  A list deleted between any of these yields a `:list` book whose `list` is
  nil — the same rare window the web has, which is why `That list is gone` is
  ported rather than declared impossible.

  ## The collections: recipes, trackers, routines

  After the garden, the picker shelves three COLLECTION books
  (`Books.collections/0`): read-mostly views over `App.Recipes`, `App.Trackers`
  and `App.Routines`. They are books in the picker, not extra state sections,
  for two reasons: `select_book` and the remembered pref then work for them
  unchanged, and the picker renders exactly the list the server sent. Each one's
  body rides `state` like `list`/`garden` do, non-nil only while it is the
  current book, formatted by `AppWeb.CollectionFormat`.

  This is why `state/1` reads `Books.shelf/1` and `Books.current_on_shelf/1`
  rather than `for_user/1`/`current/1`. Those two stay lists + garden, because
  the web dashboard renders them and has no body for a collection.

  Their writes are deliberately few: `delete_recipe` and `delete_routine`,
  nothing else (no Clear, no tracker edits). Both resolve the client's id
  against the user's own visible set and then go through the context's own
  delete. A recipe's delete passes the row's OWN scope explicitly
  (`:household`/`:personal`): a private variant and a shared recipe can share a
  name, and only the id says which one the user read. All three contexts
  broadcast (`{:recipes_changed}` on `recipes:household` or `recipes:<uid>`,
  `{:trackers_changed}`/`{:routines_changed}` on their `:<uid>` topics), so
  these ride the subscription like the list writes do and never push for
  themselves.
  """
  use AppWeb, :channel

  alias App.{Books, Garden, Lists, Recipes, Routines, Trackers, Users}
  alias AppWeb.{BookFormat, CollectionFormat}

  @impl true
  def join("panel:books:" <> _ignored, _payload, socket) do
    # The suffix is ignored; the user is whoever the token authenticated.
    uid = socket.assigns.user_id
    Phoenix.PubSub.subscribe(App.PubSub, "lists:#{uid}")
    Phoenix.PubSub.subscribe(App.PubSub, "lists:household")
    Phoenix.PubSub.subscribe(App.PubSub, "garden:#{uid}")
    Phoenix.PubSub.subscribe(App.PubSub, "garden:household")
    # The collections. A private recipe broadcasts only on its owner's topic, so
    # the other person's private edits never even wake this channel.
    Phoenix.PubSub.subscribe(App.PubSub, "recipes:#{uid}")
    Phoenix.PubSub.subscribe(App.PubSub, "recipes:household")
    Phoenix.PubSub.subscribe(App.PubSub, "trackers:#{uid}")
    Phoenix.PubSub.subscribe(App.PubSub, "routines:#{uid}")
    send(self(), :push_state)
    {:ok, socket}
  end

  # ---- inbound: the list writes ----
  #
  # None of these pushes `state`. Every context call below ends in
  # `Lists.broadcast_changed/2`, PubSub delivers a broadcast to its sender, and
  # join/2 subscribed us — so the re-push is the SUBSCRIPTION's job. See the
  # moduledoc for the two writes where that is not true.
  #
  # Every id is client-supplied and is resolved against this user's VISIBLE set
  # (own rows + household rows), never `Repo.get/2`.
  @impl true
  def handle_in("add_item", %{"list_id" => id, "text" => text}, socket)
      when is_integer(id) and is_binary(text) do
    with %{} = list <- own_list(socket, id),
         trimmed when trimmed != "" <- String.trim(text) do
      Lists.add_item(list, trimmed)
      {:reply, :ok, socket}
    else
      _ -> {:reply, {:error, %{reason: "bad_request"}}, socket}
    end
  end

  def handle_in("toggle_item", %{"id" => id}, socket) when is_integer(id) do
    case own_item(socket, id) do
      nil ->
        {:reply, {:error, %{reason: "bad_request"}}, socket}

      %{checked_at: nil} = item ->
        Lists.check_item(item)
        {:reply, :ok, socket}

      item ->
        Lists.uncheck_item(item)
        {:reply, :ok, socket}
    end
  end

  def handle_in("clear_done", %{"list_id" => id}, socket) when is_integer(id) do
    case own_list(socket, id) do
      nil ->
        {:reply, {:error, %{reason: "bad_request"}}, socket}

      list ->
        Lists.clear_checked(list)
        {:reply, :ok, socket}
    end
  end

  def handle_in("delete_list", %{"list_id" => id}, socket) when is_integer(id) do
    case own_list(socket, id) do
      nil ->
        {:reply, {:error, %{reason: "bad_request"}}, socket}

      list ->
        # The stored pref may now name a deleted list; nothing needs to clean it
        # up, because state/1 re-resolves the key on every push and a stale one
        # falls back. Same as the web (conversation_live.ex:246).
        Lists.delete_list(list)
        {:reply, :ok, socket}
    end
  end

  # ---- inbound: garden writes ----
  #
  # Same rule as the list writes: every one of these broadcasts, so the
  # subscription does the re-push.
  def handle_in("add_note", %{"plant_id" => id, "body" => body}, socket)
      when is_integer(id) and is_binary(body) do
    with %{} = plant <- own_plant(socket, id, :active),
         trimmed when trimmed != "" <- String.trim(body) do
      Garden.add_note(plant, trimmed)
      {:reply, :ok, socket}
    else
      _ -> {:reply, {:error, %{reason: "bad_request"}}, socket}
    end
  end

  def handle_in("archive_plant", %{"id" => id}, socket) when is_integer(id) do
    case own_plant(socket, id, :active) do
      nil ->
        {:reply, {:error, %{reason: "bad_request"}}, socket}

      plant ->
        Garden.archive_plant(plant)
        {:reply, :ok, socket}
    end
  end

  def handle_in("revive_plant", %{"id" => id}, socket) when is_integer(id) do
    case own_plant(socket, id, :archived) do
      nil ->
        {:reply, {:error, %{reason: "bad_request"}}, socket}

      plant ->
        Garden.revive_plant(plant)
        {:reply, :ok, socket}
    end
  end

  # ---- inbound: book-level writes ----

  # The `key` is a PRECONDITION, never the target. The server still resolves the
  # book itself, exactly as it always did; the client's key only says which book
  # the user was LOOKING AT when they consented.
  #
  # An earlier version took no argument, on the reasoning that a server-derived
  # target cannot be steered by a stale client. That reasoning was backwards,
  # and it shipped a real bug: `clear_confirm` is a SNAPSHOT pushed with `state`,
  # while the target was re-resolved from the shared `books_last_book` pref at
  # tap time — and `Users.update_prefs/2` broadcasts nothing (users.ex:86-88),
  # so a `select_book` on the WEB never reaches an open native panel. The user
  # then read "Clear everything off Groceries?" and closed out the GARDEN
  # season instead.
  #
  # The web is not a precedent for the old shape: `conversation_live.ex:280`
  # reads its OWN session assign, so its dialog and its action come from one
  # self-consistent snapshot. This channel reads a pref another surface can
  # change underneath it. Consent is bound to what the user read, so the read
  # has to be part of the request.
  def handle_in("clear_book", %{"key" => key}, socket) when is_binary(key) do
    # Same nil-user guard as state/1 (Users.get/1 can return nil — see its own
    # doc): every branch below dereferences the user, so an unguarded nil
    # crashes the channel with a BadMapError instead of replying bad_request.
    case Users.get(socket.assigns.user_id) do
      nil ->
        {:reply, {:error, %{reason: "bad_request"}}, socket}

      user ->
        # Over the SHELF: the precondition is checked against the same current
        # book state/1 showed, collections included.
        current = Books.current_on_shelf(user)

        if current.key == key do
          # Books.clear/1 returns {:error, :not_found} when the list was deleted
          # between resolve and click (books.ex:90-98). Ignore the outcome rather
          # than hard-matching :ok — a MatchError here kills the panel, and the
          # next push re-resolves to a fallback anyway. conversation_live.ex:276-279
          # explains it. A collection has no Clear at all (its clear_confirm is
          # nil, so the panel shows no control): refuse a probe outright.
          case Books.clear(current) do
            {:error, :not_clearable} -> {:reply, {:error, %{reason: "bad_request"}}, socket}
            _ -> {:reply, :ok, socket}
          end
        else
          # Destroy NOTHING, and push the truth so the panel corrects itself and
          # the user can re-read a dialog that matches reality.
          {:reply, {:error, %{reason: "stale"}}, push_state(socket)}
        end
    end
  end

  # THIS ONE PUSHES. update_prefs/2 has no broadcast at all (users.ex:86-88).
  def handle_in("select_book", %{"key" => key}, socket) when is_binary(key) do
    case Users.get(socket.assigns.user_id) do
      nil ->
        {:reply, {:error, %{reason: "bad_request"}}, socket}

      user ->
        case Books.resolve_on_shelf(key, user) do
          :not_found ->
            {:reply, {:error, %{reason: "bad_request"}}, socket}

          {:ok, _book} ->
            {:ok, _updated} = Users.update_prefs(user, %{books_last_book: key})
            {:reply, :ok, push_state(socket)}
        end
    end
  end

  # SO DOES THIS ONE. find_or_create_list/2 is the only mutating function in
  # App.Lists without a broadcast (lists.ex:19-43), and update_prefs/2 has none
  # either — so BOTH halves of this handler are silent. Ride it and creating a
  # list looks like a dead button.
  def handle_in("new_list", %{"name" => name}, socket) when is_binary(name) do
    case Users.get(socket.assigns.user_id) do
      nil ->
        {:reply, {:error, %{reason: "bad_request"}}, socket}

      user ->
        case String.trim(name) do
          "" ->
            {:reply, {:error, %{reason: "bad_request"}}, socket}

          trimmed ->
            # Personal, never household: the web's own new-list form does the
            # same (conversation_live.ex:263). Sharing a list is a voice
            # affordance.
            list = Lists.find_or_create_list(%{user_id: user.id, household: false}, trimmed)
            {:ok, _updated} = Users.update_prefs(user, %{books_last_book: "list:#{list.id}"})
            {:reply, :ok, push_state(socket)}
        end
    end
  end

  # ---- inbound: the collections' two deletes ----
  #
  # Neither pushes: Recipes.delete/3 and Routines.delete/2 broadcast, and join/2
  # subscribed us. The id names exactly the row whose confirmation the user read
  # (the confirmation is per row), so there is no stale-target window like
  # clear_book's.

  # The id resolves against Recipes.list/1 — own private + household, never
  # Repo.get/2 — so the other person's private recipe is not in the search
  # space. Then the delete goes through the context by name with the row's OWN
  # scope, and only after re-resolving that name in that scope lands on the
  # same id: a name that resolved anywhere else deletes nothing.
  def handle_in("delete_recipe", %{"id" => id}, socket) when is_integer(id) do
    uid = socket.assigns.user_id

    with %{} = recipe <- Enum.find(Recipes.list(uid), &(&1.id == id)),
         scope = if(recipe.household, do: :household, else: :personal),
         {:ok, %{id: ^id}} <- Recipes.get(uid, recipe.name, scope),
         {:ok, _deleted} <- Recipes.delete(uid, recipe.name, scope) do
      {:reply, :ok, socket}
    else
      _ -> {:reply, {:error, %{reason: "bad_request"}}, socket}
    end
  end

  # Routines are per-user: Routines.list/1 is the whole search space. Same
  # re-resolve-then-delete guard as above, since Routines.delete/2 is by phrase.
  def handle_in("delete_routine", %{"id" => id}, socket) when is_integer(id) do
    uid = socket.assigns.user_id

    with %{} = routine <- Enum.find(Routines.list(uid), &(&1.id == id)),
         %{id: ^id} <- Routines.get(uid, routine.name),
         {:ok, _deleted} <- Routines.delete(uid, routine.name) do
      {:reply, :ok, socket}
    else
      _ -> {:reply, {:error, %{reason: "bad_request"}}, socket}
    end
  end

  # A client bug — or a probe — must not crash the channel and drop the panel.
  def handle_in(_event, _payload, socket),
    do: {:reply, {:error, %{reason: "bad_request"}}, socket}

  @impl true
  def handle_info(:push_state, socket), do: {:noreply, push_state(socket)}
  def handle_info({:lists_changed}, socket), do: {:noreply, push_state(socket)}
  def handle_info({:garden_changed}, socket), do: {:noreply, push_state(socket)}
  def handle_info({:recipes_changed}, socket), do: {:noreply, push_state(socket)}
  def handle_info({:trackers_changed}, socket), do: {:noreply, push_state(socket)}
  def handle_info({:routines_changed}, socket), do: {:noreply, push_state(socket)}

  @doc false
  # Public so Tasks 2 and 3's handlers can push after a non-broadcasting write.
  # `state/1` returns nil for a deleted user (see its own guard below); a nil
  # user means nothing to push, not a crash.
  def push_state(socket) do
    case state(socket.assigns.user_id) do
      nil ->
        socket

      payload ->
        push(socket, "state", payload)
        socket
    end
  end

  @doc false
  # Same nil guard as SettingsChannel's/VoiceLockChannel's: Users.get/1 can
  # return nil (no user-deletion path exists today, so this is defence-in-
  # depth, not a live bug) — Books.for_user/1 has no clause for a nil user
  # (it immediately dereferences user.id), so guard it here rather than let a
  # bad :user_id crash the channel between join and its first push_state.
  def state(uid) do
    case Users.get(uid) do
      nil ->
        nil

      user ->
        # The pref lives on the user row (`books_last_book`), and the socket
        # carries only the id — so re-read the user on every push or
        # `select_book` would render the value it replaced.
        books = Books.shelf(user)
        current = Books.current_on_shelf(user)

        %{
          books: Enum.map(books, &book/1),
          current_key: current.key,
          clear_confirm: BookFormat.clear_confirm(current),
          list: list_body(current, uid),
          garden: garden_body(current, uid),
          recipes: recipes_body(current, uid),
          trackers: trackers_body(current, uid),
          routines: routines_body(current, uid)
        }
    end
  end

  # ---- the collections' bodies: each nil unless it is the current book ----

  # Recipes.list/1 IS the scoping rule: own private + household, never the
  # other person's private ones.
  defp recipes_body(%{kind: :recipes}, uid), do: CollectionFormat.recipes(Recipes.list(uid))
  defp recipes_body(_book, _uid), do: nil

  # Trackers are private, always: list/1 and each tracker's own entries are the
  # user's alone. Every entry is read so the detail can show the newest ones
  # even when nothing fell in the chart's window.
  defp trackers_body(%{kind: :trackers}, uid) do
    rows = Trackers.list(uid)
    entries = Map.new(rows, &{&1.tracker.id, Trackers.all_entries(&1.tracker)})
    CollectionFormat.trackers(rows, entries, DateTime.utc_now(), App.Config.timezone())
  end

  defp trackers_body(_book, _uid), do: nil

  defp routines_body(%{kind: :routines}, uid),
    do: CollectionFormat.routines(Routines.list(uid), DateTime.utc_now(), App.Config.timezone())

  defp routines_body(_book, _uid), do: nil

  defp book(b),
    do: %{key: b.key, label: b.label, kind: Atom.to_string(b.kind), icon: icon(b.icon)}

  # `Books.list_icon/1` returns the web's `hero-*` class; the Dart asset name is
  # the bare part, so strip it once here rather than in every client.
  defp icon("hero-" <> name), do: name
  defp icon(other), do: other

  defp list_body(%{kind: :list, id: id}, uid) do
    # The id came from a book in THIS user's own set, but the lookup still goes
    # through list_visible/1 so there is exactly one rule for what is reachable.
    case Enum.find(Lists.list_visible(uid), &(&1.id == id)) do
      nil ->
        nil

      list ->
        %{
          id: list.id,
          name: list.name,
          household: list.household,
          items: Enum.map(BookFormat.sorted_items(list), &item/1)
        }
    end
  end

  defp list_body(_book, _uid), do: nil

  # VISIBLE, not owned: list_visible/1 is `user_id == ^uid or household == true`
  # (lists.ex:53), so a household list belonging to the other user is reachable
  # — that is the product's sharing rule, not a leak.
  defp own_list(socket, id),
    do: Enum.find(Lists.list_visible(socket.assigns.user_id), &(&1.id == id))

  # Items are reached only THROUGH a visible list, so an item on someone else's
  # personal list is simply not in the search space.
  defp own_item(socket, id) do
    socket.assigns.user_id
    |> Lists.list_visible()
    |> Enum.flat_map(& &1.items)
    |> Enum.find(&(&1.id == id))
  end

  # Plants are resolved out of the user's own VISIBLE garden (own + household,
  # garden.ex:42) — never Repo.get/2. `which` keeps archive and revive honest:
  # archiving an archived plant is a no-op in the context (garden.ex:92) and
  # reviving an active one is meaningless, so each looks only where it makes
  # sense, exactly as the web does (conversation_live.ex:301, :312-316).
  defp own_plant(socket, id, which) do
    g = Garden.garden(socket.assigns.user_id)

    pool =
      case which do
        :active -> g.active
        :archived -> Enum.flat_map(g.archived_by_season, fn {_season, ps} -> ps end)
      end

    Enum.find(pool, &(&1.id == id))
  end

  defp item(i), do: %{id: i.id, text: i.text, checked: i.checked_at != nil}

  defp garden_body(%{kind: :garden}, uid) do
    g = Garden.garden(uid)

    %{
      active: Enum.map(g.active, &plant/1),
      # A LIST of {season, plants}, never a map: the descending order is the
      # point, and JSON object key order does not survive to Dart.
      past:
        for {season, plants} <- BookFormat.seasons_desc(g.archived_by_season) do
          %{season: season, plants: Enum.map(plants, &archived/1)}
        end
    }
  end

  defp garden_body(_book, _uid), do: nil

  defp plant(p) do
    %{
      id: p.id,
      name: p.name,
      household: p.household,
      meta: BookFormat.plant_meta(p),
      notes: Enum.map(p.notes, &%{body: &1.body, noted: BookFormat.fmt_noted(&1)})
    }
  end

  # The Past seasons list is read-only but for Revive, so it carries no notes
  # and no meta — never the %Plant{} struct.
  defp archived(p), do: %{id: p.id, name: p.name, household: p.household}
end
