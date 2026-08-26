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

  # A client bug — or a probe — must not crash the channel and drop the panel.
  @impl true
  def handle_in(_event, _payload, socket),
    do: {:reply, {:error, %{reason: "bad_request"}}, socket}

  @impl true
  def handle_info(:push_state, socket), do: {:noreply, push_state(socket)}
  def handle_info({:lists_changed}, socket), do: {:noreply, push_state(socket)}
  def handle_info({:garden_changed}, socket), do: {:noreply, push_state(socket)}

  @doc false
  # Public so Tasks 2 and 3's handlers can push after a non-broadcasting write.
  def push_state(socket) do
    push(socket, "state", state(socket.assigns.user_id))
    socket
  end

  @doc false
  def state(uid) do
    # The pref lives on the user row (`books_last_book`), and the socket carries
    # only the id — so re-read the user on every push or `select_book` would
    # render the value it replaced.
    user = Users.get(uid)
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
