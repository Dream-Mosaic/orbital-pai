defmodule AppWeb.Panels.BooksChannel do
  @moduledoc """
  The native Books drawer's data path — a bottom-nav station like Reminders and
  Connectors. Joined only while the drawer is on screen: join MEANS open.

  Non-essential: a refusal stops this channel and leaves the conversation alone.

  ## This channel is HYBRID, and that is the whole trap

  Eight of its ten writes go through `App.Lists`/`App.Garden`, which broadcast,
  so this channel RIDES them: it subscribes to four topics in `join/2` and
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

  So `select_book` and `new_list` push `state` THEMSELVES; the other eight must
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

  ## Two queries, and the nudge that follows from them

  `Books.for_user/1` calls `Lists.list_visible/1` itself (`books.ex:34`), so a
  push that also needs items has issued two queries however it is written. A
  list deleted between them yields a `:list` book whose `list` is nil — the same
  rare window the web has, which is why `That list is gone` is ported rather
  than declared impossible.
  """
  use AppWeb, :channel

  alias App.{Books, Garden, Lists, Users}
  alias AppWeb.BookFormat

  @impl true
  def join("panel:books:" <> _ignored, _payload, socket) do
    # The suffix is ignored; the user is whoever the token authenticated.
    uid = socket.assigns.user_id
    Phoenix.PubSub.subscribe(App.PubSub, "lists:#{uid}")
    Phoenix.PubSub.subscribe(App.PubSub, "lists:household")
    Phoenix.PubSub.subscribe(App.PubSub, "garden:#{uid}")
    Phoenix.PubSub.subscribe(App.PubSub, "garden:household")
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

  # A client bug — or a probe — must not crash the channel and drop the panel.
  def handle_in(_event, _payload, socket),
    do: {:reply, {:error, %{reason: "bad_request"}}, socket}

  @impl true
  def handle_info(:push_state, socket), do: {:noreply, push_state(socket)}
  def handle_info({:lists_changed}, socket), do: {:noreply, push_state(socket)}
  def handle_info({:garden_changed}, socket), do: {:noreply, push_state(socket)}

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
        books = Books.for_user(user)
        current = current_book(books, user)

        %{
          books: Enum.map(books, &book/1),
          current_key: current.key,
          clear_confirm: BookFormat.clear_confirm(current),
          list: list_body(current, uid),
          garden: garden_body(current, uid)
        }
    end
  end

  # conversation_live.ex:584-600, verbatim. Fallback priority is the HOUSEHOLD
  # "groceries" list, THEN the first book — not merely the first book.
  # `Books.for_user/1` always appends the garden last, so with no lists at all
  # "the first book" IS the garden.
  defp current_book(books, user) do
    case Books.resolve(user.books_last_book, user) do
      {:ok, book} -> book
      :not_found -> Enum.find(books, &household_groceries?/1) || List.first(books)
    end
  end

  defp household_groceries?(%{kind: :list, label: label, scope: %{household: true}}),
    do: String.downcase(label) == "groceries"

  defp household_groceries?(_book), do: false

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
