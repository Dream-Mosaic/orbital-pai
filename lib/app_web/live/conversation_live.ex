defmodule AppWeb.ConversationLive do
  @moduledoc """
  The voice-first home screen (`/`).

  Renders a minimal shell containing the `Voice` JS hook region and a top bar.
  Memory, reminders, connector, and settings panels are slide-in modals on this page.
  """
  use AppWeb, :live_view
  import AppWeb.VoiceModals

  alias App.Memory
  alias App.Reminders
  alias App.Lists
  alias App.Garden
  alias App.Books
  alias App.Google.Accounts, as: GoogleAccounts
  alias App.Google.Connectors

  # Kiosk-only ambient info strip (weather · next event · due reminders) refresh cadence.
  @ambient_refresh_ms 5 * 60_000

  @impl true
  def mount(params, _session, socket) do
    sid = to_string(socket.assigns.current_user.id)
    kiosk = params["kiosk"] == "1"

    switchable_users =
      if kiosk and App.Config.default().kiosk_user_switch do
        # Only allowlisted users are switchable (matches the controller gate) — a de-allowlisted
        # but still-present DB row must not render a switch button that would just 403 on tap.
        App.Users.list()
        |> Enum.filter(&App.Users.allowed?(&1.email))
        |> Enum.reject(&(&1.id == socket.assigns.current_user.id))
      else
        []
      end

    if connected?(socket) do
      Memory.subscribe()
      Phoenix.PubSub.subscribe(App.PubSub, "reminders:#{sid}")
      Phoenix.PubSub.subscribe(App.PubSub, "reminders:household")
      Phoenix.PubSub.subscribe(App.PubSub, "lists:#{sid}")
      Phoenix.PubSub.subscribe(App.PubSub, "lists:household")
      Phoenix.PubSub.subscribe(App.PubSub, "garden:#{sid}")
      Phoenix.PubSub.subscribe(App.PubSub, "garden:household")
      Phoenix.PubSub.subscribe(App.PubSub, "presence:voice")
      Phoenix.PubSub.subscribe(App.PubSub, "voice_lock:#{sid}")
      if kiosk, do: send(self(), :refresh_ambient)
    end

    {:ok,
     socket
     |> assign(
       session_id: sid,
       user_token: AppWeb.UserAuth.socket_token(socket.assigns.current_user.id),
       stt_sample_rate: App.Config.default().stt_sample_rate,
       tts_sample_rate: App.Config.default().tts_sample_rate,
       app_version: App.version(),
       user_name: socket.assigns.current_user.name,
       page_title: App.Config.default().name,
       kiosk: kiosk,
       switchable_users: switchable_users,
       modal_open: false,
       modal: nil,
       grant: nil,
       default_abi: socket.assigns.current_user.default_abi,
       default_ptt: socket.assigns.current_user.default_ptt,
       voice_activation: socket.assigns.current_user.voice_activation,
       briefing_time: socket.assigns.current_user.briefing_time,
       relock_seconds: socket.assigns.current_user.relock_seconds,
       assistant_name: App.Config.default().name,
       ambient: %{weather: nil, next_event: nil},
       present: if(connected?(socket), do: present_list(), else: [])
     )
     |> load_memory()
     |> load_reminders()
     |> load_lists()
     |> load_garden()
     |> load_books()
     |> load_google_accounts()
     |> load_voice_lock()}
  end

  @impl true
  def handle_event("clear_conversation", _params, socket) do
    App.Memory.clear_turns(socket.assigns.current_user.id)
    clear_live_fsm(socket)

    {:noreply,
     socket
     |> put_flash(:info, "Conversation cleared.")
     |> push_event("clear_log", %{})}
  end

  def handle_event("add_fact", %{"content" => content}, socket) do
    content = String.trim(content)

    socket =
      if content == "" do
        socket
      else
        case Memory.create_fact(%{
               content: content,
               source: "user",
               user_id: socket.assigns.current_user.id
             }) do
          {:ok, _} -> load_memory(socket)
          {:error, _} -> put_flash(socket, :error, "Couldn't save that fact.")
        end
      end

    {:noreply, socket}
  end

  def handle_event("delete_fact", %{"id" => id}, socket) do
    id = String.to_integer(id)

    case Enum.find(socket.assigns.facts, &(&1.id == id)) do
      nil -> :ok
      fact -> Memory.delete_fact(fact)
    end

    {:noreply, load_memory(socket)}
  end

  def handle_event("save_summary", %{"summary" => summary}, socket) do
    Memory.put_summary(socket.assigns.current_user.id, summary)
    {:noreply, socket |> load_memory() |> put_flash(:info, "Summary saved.")}
  end

  def handle_event("refresh_memory", _params, socket) do
    {:noreply, load_memory(socket)}
  end

  def handle_event("forget_me", _params, socket) do
    Memory.forget(socket.assigns.current_user.id)
    clear_live_fsm(socket)

    {:noreply,
     socket
     |> put_flash(:info, "Memory cleared.")
     |> load_memory()
     |> push_event("clear_log", %{})}
  end

  @valid_modals ~w(memory reminders lists garden connectors settings voice_lock books)a

  def handle_event("open_modal", %{"modal" => modal}, socket) do
    case Enum.find(@valid_modals, &(to_string(&1) == modal)) do
      nil -> {:noreply, socket}
      atom -> {:noreply, assign(socket, modal_open: true, modal: atom)}
    end
  end

  def handle_event("close_modal", _params, %{assigns: %{modal_open: false}} = socket),
    do: {:noreply, socket}

  def handle_event("close_modal", _params, socket),
    do: {:noreply, assign(socket, modal_open: false)}

  def handle_event("dismiss_reminder", %{"id" => id}, socket) do
    id = String.to_integer(id)

    case Enum.find(socket.assigns.due ++ socket.assigns.upcoming, &(&1.id == id)) do
      nil -> :ok
      reminder -> Reminders.delete(reminder)
    end

    {:noreply, load_reminders(socket)}
  end

  def handle_event("ack_reminder", %{"id" => id}, socket) do
    id = String.to_integer(id)

    case Enum.find(socket.assigns.due, &(&1.id == id)) do
      nil -> :ok
      reminder -> Reminders.acknowledge(reminder)
    end

    {:noreply, load_reminders(socket)}
  end

  def handle_event("toggle_list_item", %{"id" => id}, socket) do
    id = String.to_integer(id)

    case find_list_item(socket, id) do
      nil -> :ok
      %{checked_at: nil} = item -> Lists.check_item(item)
      item -> Lists.uncheck_item(item)
    end

    {:noreply, load_lists(socket)}
  end

  def handle_event("add_list_item", %{"list_id" => list_id, "text" => text}, socket) do
    text = String.trim(text)
    list_id = String.to_integer(list_id)

    if text != "" do
      case Enum.find(socket.assigns.lists, &(&1.id == list_id)) do
        nil -> :ok
        list -> Lists.add_item(list, text)
      end
    end

    {:noreply, load_lists(socket)}
  end

  def handle_event("clear_list_checked", %{"id" => id}, socket) do
    id = String.to_integer(id)

    case Enum.find(socket.assigns.lists, &(&1.id == id)) do
      nil -> :ok
      list -> Lists.clear_checked(list)
    end

    {:noreply, load_lists(socket)}
  end

  def handle_event("delete_list", %{"id" => id}, socket) do
    id = String.to_integer(id)

    case Enum.find(socket.assigns.lists, &(&1.id == id)) do
      nil -> :ok
      list -> Lists.delete_list(list)
    end

    {:noreply, load_lists(socket)}
  end

  def handle_event("add_plant_note", %{"plant_id" => plant_id, "body" => body}, socket) do
    body = String.trim(body)
    plant_id = String.to_integer(plant_id)

    if body != "" do
      case Enum.find(socket.assigns.garden.active, &(&1.id == plant_id)) do
        nil -> :ok
        plant -> Garden.add_note(plant, body)
      end
    end

    {:noreply, load_garden(socket)}
  end

  def handle_event("archive_plant", %{"id" => id}, socket) do
    id = String.to_integer(id)

    case Enum.find(socket.assigns.garden.active, &(&1.id == id)) do
      nil -> :ok
      plant -> Garden.archive_plant(plant)
    end

    {:noreply, load_garden(socket)}
  end

  def handle_event("revive_plant", %{"id" => id}, socket) do
    id = String.to_integer(id)

    archived =
      socket.assigns.garden.archived_by_season
      |> Enum.flat_map(fn {_season, plants} -> plants end)

    case Enum.find(archived, &(&1.id == id)) do
      nil -> :ok
      plant -> Garden.revive_plant(plant)
    end

    {:noreply, load_garden(socket)}
  end

  def handle_event("disconnect_connection", %{"account" => id, "connector" => connector}, socket) do
    account = account_by_id(socket, id)
    connector = parse_connector(connector, hd(Connectors.all()))

    cond do
      is_nil(account) ->
        {:noreply, load_google_accounts(socket)}

      Connectors.granted(account) == [connector] ->
        GoogleAccounts.delete(account)
        {:noreply, load_google_accounts(socket)}

      true ->
        {:noreply, redirect(socket, to: change_access_path(account, connector, :none))}
    end
  end

  def handle_event("grant_open", _params, socket) do
    first = hd(Connectors.all())
    grant = %{connector: first, account_id: :new, level: default_level(first)}
    {:noreply, assign(socket, grant: grant)}
  end

  def handle_event("grant_change", params, socket) do
    current =
      socket.assigns.grant ||
        %{connector: hd(Connectors.all()), account_id: :new, level: :read}

    connector = parse_connector(params["connector"], current.connector)

    grant = %{
      connector: connector,
      account_id: parse_account(params["account"], current.account_id),
      level: parse_level(params["level"], connector, current.level)
    }

    {:noreply, assign(socket, grant: grant)}
  end

  def handle_event("grant_cancel", _params, socket) do
    {:noreply, assign(socket, grant: nil)}
  end

  def handle_event("grant_submit", _params, socket) do
    grant = socket.assigns.grant

    cond do
      is_nil(grant) ->
        {:noreply, socket}

      grant_noop?(grant) ->
        {:noreply, assign(socket, grant: nil)}

      true ->
        case grant_path(socket, grant) do
          nil -> {:noreply, assign(socket, grant: nil)}
          path -> {:noreply, redirect(socket, to: path)}
        end
    end
  end

  def handle_event("update_pref", %{"pref" => pref}, socket)
      when pref in ~w(default_abi default_ptt voice_activation) do
    user = socket.assigns.current_user
    key = String.to_existing_atom(pref)
    {:ok, user} = App.Users.update_prefs(user, %{key => !Map.get(user, key)})

    {:noreply,
     assign(socket,
       current_user: user,
       default_abi: user.default_abi,
       default_ptt: user.default_ptt,
       voice_activation: user.voice_activation
     )}
  end

  def handle_event("update_pref", _params, socket), do: {:noreply, socket}

  def handle_event("toggle_briefing", _params, socket) do
    user = socket.assigns.current_user
    new_value = if user.briefing_time, do: nil, else: "07:00"
    {:ok, user} = App.Users.update_prefs(user, %{briefing_time: new_value})
    {:noreply, assign(socket, current_user: user, briefing_time: user.briefing_time)}
  end

  def handle_event("set_briefing_time", %{"briefing_time" => hhmm}, socket) do
    case App.Users.update_prefs(socket.assigns.current_user, %{briefing_time: hhmm}) do
      {:ok, user} ->
        {:noreply, assign(socket, current_user: user, briefing_time: user.briefing_time)}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_event("set_relock", %{"seconds" => secs}, socket) do
    seconds = secs |> parse_seconds() |> max(10) |> min(30)
    {:ok, user} = App.Users.update_prefs(socket.assigns.current_user, %{relock_seconds: seconds})

    {:noreply,
     socket
     |> assign(current_user: user, relock_seconds: user.relock_seconds)
     |> push_event("set_relock", %{seconds: user.relock_seconds})}
  end

  def handle_event("set_default_google", %{"id" => id}, socket) do
    id = String.to_integer(id)

    case Enum.find(socket.assigns.google_accounts, &(&1.id == id)) do
      nil -> :ok
      account -> GoogleAccounts.set_default(account)
    end

    {:noreply, load_google_accounts(socket)}
  end

  def handle_event("voice_lock_mode", %{"mode" => mode}, socket) do
    {:ok, user} = App.Speaker.set_mode(socket.assigns.current_user, mode)
    {:noreply, socket |> assign(current_user: user) |> load_voice_lock()}
  end

  def handle_event("enroll_record", %{"slot" => slot}, socket) do
    slot = String.to_integer(to_string(slot))
    vl = %{socket.assigns.voice_lock | recording_slot: slot, enroll_error: nil}
    {:noreply, socket |> assign(voice_lock: vl) |> push_event("enroll:record", %{slot: slot})}
  end

  def handle_event("enroll_status", _params, socket), do: {:noreply, socket}

  def handle_event("enroll_result", %{"slot" => slot, "ok" => ok} = params, socket) do
    error = if ok, do: nil, else: {slot, "failed: #{params["reason"]}"}
    socket = load_voice_lock(socket)
    vl = %{socket.assigns.voice_lock | recording_slot: nil, enroll_error: error}
    {:noreply, assign(socket, voice_lock: vl)}
  end

  @impl true
  def handle_info(:memory_updated, socket) do
    {:noreply, load_memory(socket)}
  end

  def handle_info({:reminder_due, _r}, socket) do
    {:noreply, load_reminders(socket)}
  end

  def handle_info({:reminders_changed}, socket) do
    {:noreply, load_reminders(socket)}
  end

  def handle_info({:lists_changed}, socket) do
    {:noreply, load_lists(socket)}
  end

  def handle_info({:garden_changed}, socket) do
    {:noreply, load_garden(socket)}
  end

  def handle_info({:voice_lock_changed}, socket), do: {:noreply, load_voice_lock(socket)}

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket),
    do: {:noreply, assign(socket, present: present_list())}

  # Self-rearming ambient refresh — only kiosk mount ever sends the first message (see mount/3), so
  # a non-kiosk LiveView never enters this clause and never fetches. `%{}` args for the calendar
  # call default its window to now→+24h (App.Tools.Calendar.time_min/time_max), which is exactly
  # the "what's next" window `AppWeb.Ambient.next_event_line/2` wants.
  def handle_info(:refresh_ambient, socket) do
    Process.send_after(self(), :refresh_ambient, @ambient_refresh_ms)
    uid = socket.assigns.current_user.id
    cfg = App.Config.default()

    {:noreply,
     start_async(socket, :ambient, fn ->
       ctx = %{session_id: to_string(uid), user_id: uid, config: cfg}

       weather =
         case App.Tools.execute("get_weather", %{}, ctx) do
           {:ok, r} -> r
           _ -> nil
         end

       events =
         case App.Tools.execute("get_calendar_events", %{}, ctx) do
           {:ok, r} -> r
           _ -> nil
         end

       %{
         weather: AppWeb.Ambient.weather_line(weather),
         next_event: AppWeb.Ambient.next_event_line(events, DateTime.utc_now())
       }
     end)}
  end

  @impl true
  def handle_async(:ambient, {:ok, ambient}, socket),
    do: {:noreply, assign(socket, ambient: ambient)}

  def handle_async(:ambient, {:exit, _reason}, socket), do: {:noreply, socket}

  # Kiosk ambient strip: the present segments joined with " · " — a missing/errored source (nil
  # weather or next_event, or zero due reminders) simply drops out, with no dangling separator.
  defp ambient_line(ambient, due) do
    reminders =
      case length(due) do
        0 -> nil
        1 -> "1 reminder due"
        n -> "#{n} reminders due"
      end

    [ambient.weather, ambient.next_event, reminders]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp present_list do
    AppWeb.Presence.list("presence:voice")
    |> Enum.map(fn {_id, %{metas: [m | _]}} -> %{name: m.name, kiosk: m.kiosk} end)
  end

  defp load_memory(socket) do
    uid = socket.assigns.current_user.id
    assign(socket, facts: Memory.list_facts(uid), summary: Memory.get_summary(uid).content)
  end

  defp load_reminders(socket) do
    uid = socket.assigns.current_user.id

    assign(socket,
      upcoming: Reminders.list_upcoming(uid),
      due: Reminders.list_unacknowledged(uid)
    )
  end

  defp load_lists(socket) do
    assign(socket, lists: Lists.list_visible(socket.assigns.current_user.id))
  end

  defp load_garden(socket) do
    assign(socket, garden: Garden.garden(socket.assigns.current_user.id))
  end

  # The Books modal's picker + remembered current book. `user.books_last_book` (a "list:<id>" or
  # "garden" key) is resolved against the FRESH book set on every load — a stale key (the list was
  # deleted elsewhere) or a nil key (never chosen) both fall through to `fallback_book/1`.
  defp load_books(socket) do
    user = socket.assigns.current_user
    books = Books.for_user(user)
    current = resolve_current_book(books, user.books_last_book, user)
    assign(socket, books: books, current_book: current)
  end

  defp resolve_current_book(books, key, user) do
    case key && Books.resolve(key, user) do
      {:ok, book} -> book
      _ -> fallback_book(books)
    end
  end

  # Fallback priority: the household groceries list, else the first book. `Books.for_user/1`
  # always appends the garden book last, so when there are no list books at all, "the first book"
  # IS the garden book — that's how "else Garden" (the spec's third tier) is satisfied without a
  # separate branch here.
  defp fallback_book(books), do: Enum.find(books, &household_groceries?/1) || List.first(books)

  defp household_groceries?(%{kind: :list, label: label, scope: %{household: true}}),
    do: String.downcase(label) == "groceries"

  defp household_groceries?(_book), do: false

  # The Books body needs the ACTUAL list struct (with items preloaded) for a :list book — @lists
  # is already kept fresh by the existing list handlers/broadcasts, so this just looks it up by id
  # rather than re-fetching. nil when the remembered list was deleted elsewhere between loads.
  defp current_book_list(lists, %{kind: :list, id: id}), do: Enum.find(lists, &(&1.id == id))
  defp current_book_list(_lists, _book), do: nil

  defp find_list_item(socket, id) do
    socket.assigns.lists |> Enum.flat_map(& &1.items) |> Enum.find(&(&1.id == id))
  end

  defp clear_live_fsm(socket) do
    case App.Conversations.Sessions.lookup(socket.assigns.session_id) do
      {:ok, pid} -> App.Conversations.Conversation.clear_memory(pid)
      :error -> :ok
    end
  end

  defp load_google_accounts(socket) do
    assign(socket, google_accounts: GoogleAccounts.list(socket.assigns.current_user.id))
  end

  defp load_voice_lock(socket) do
    user = socket.assigns.current_user
    prev = socket.assigns[:voice_lock] || %{recording_slot: nil, enroll_error: nil}

    assign(socket,
      voice_lock: %{
        mode: user.voice_lock_mode,
        enrolled_slots: App.Speaker.enrolled_slots(user.id),
        drops: App.Speaker.recent_drops(user.id),
        verifier_ready: App.Speaker.verifier().ready?(),
        recording_slot: prev.recording_slot,
        enroll_error: prev.enroll_error
      }
    )
  end

  defp account_by_id(socket, id) do
    case to_int(id) do
      nil -> nil
      n -> Enum.find(socket.assigns.google_accounts, &(&1.id == n))
    end
  end

  defp to_int(i) when is_integer(i), do: i

  defp to_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_seconds(s) when is_integer(s), do: s

  defp parse_seconds(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> 15
    end
  end

  defp parse_seconds(_), do: 15

  defp parse_connector(s, fallback) do
    if s in Enum.map(Connectors.all(), &Atom.to_string/1),
      do: String.to_existing_atom(s),
      else: fallback
  end

  defp parse_account("new", _fallback), do: :new
  defp parse_account(nil, fallback), do: fallback
  defp parse_account(s, fallback), do: to_int(s) || fallback

  defp parse_level(s, connector, fallback) do
    valid = Enum.map(Connectors.access_levels(connector), &Atom.to_string/1)
    if s in valid, do: String.to_existing_atom(s), else: fallback
  end

  # Only a NEW account at :none is a true no-op. An EXISTING account at :none is a real change
  # (remove access) — change_access_path drops the connector from the query and the connect route
  # revokes it.
  defp grant_noop?(%{account_id: :new, level: :none}), do: true
  defp grant_noop?(_grant), do: false

  # highest selectable level for a connector (access_levels is lowest→highest)
  defp default_level(connector), do: List.last(Connectors.access_levels(connector))

  # New account: request exactly the chosen connector at the chosen level (skip a no-op none).
  defp grant_path(_socket, %{account_id: :new, connector: c, level: l}) when l != :none do
    "/auth/google/connect?" <> URI.encode_query(%{Atom.to_string(c) => Atom.to_string(l)})
  end

  defp grant_path(_socket, %{account_id: :new}), do: nil

  # Existing account: reuse change_access_path so the account's OTHER connectors are preserved.
  defp grant_path(socket, %{account_id: id, connector: c, level: l}) do
    case account_by_id(socket, id) do
      nil -> nil
      account -> change_access_path(account, c, l)
    end
  end

  # Build a connect path that sets `conn` to `level` for `account`, preserving the account's current
  # access on every OTHER connector (so changing one connector never silently reduces another).
  defp change_access_path(account, conn, level) do
    query =
      Connectors.all()
      |> Map.new(fn c -> {c, Connectors.access(account, c)} end)
      |> Map.put(conn, level)
      |> Enum.reject(fn {_c, lvl} -> lvl == :none end)
      |> Enum.map(fn {c, lvl} -> {c, Atom.to_string(lvl)} end)
      |> Map.new()
      |> Map.put("account", account.id)
      |> URI.encode_query()

    "/auth/google/connect?" <> query
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="voice-shell" data-theme="dark" class="meridian">
      <Layouts.flash_group flash={@flash} />

      <main
        data-kiosk={to_string(@kiosk)}
        class={[
          "h-[100dvh] flex flex-col gap-3 px-4 py-4",
          if(@kiosk, do: "kiosk w-full", else: "mx-auto max-w-[26rem]")
        ]}
      >
        <header>
          <div class="hd-l">
            <span class="wordmark">{@assistant_name}</span>
            <%!-- server/connection status: green=connected, amber=reconnecting, red=offline --%>
            <span
              id="state-dot"
              class="dot"
              data-conn="connecting"
              title={"#{@assistant_name} server status"}
            ></span>
          </div>
          <div class="hd-r">
            <nav :if={@kiosk} id="kiosk-modal-strip" class="strip">
              <button
                type="button"
                phx-click="open_modal"
                phx-value-modal="settings"
                aria-label="Settings"
                class="sbtn"
              >
                <.icon name="hero-cog-6-tooth" class="size-4" />
              </button>
              <button
                type="button"
                phx-click="open_modal"
                phx-value-modal="memory"
                aria-label="Memory"
                class="sbtn"
              >
                <.icon name="hero-sparkles" class="size-4" />
              </button>
              <button
                type="button"
                phx-click="open_modal"
                phx-value-modal="reminders"
                aria-label="Reminders"
                class="sbtn"
              >
                <span :if={@due != []} data-due-dot="true" class="duedot"></span>
                <.icon name="hero-bell" class="size-4" />
              </button>
              <button
                type="button"
                phx-click="open_modal"
                phx-value-modal="lists"
                aria-label="Lists"
                class="sbtn"
              >
                <.icon name="hero-clipboard-document-list" class="size-4" />
              </button>
              <button
                type="button"
                phx-click="open_modal"
                phx-value-modal="garden"
                aria-label="Garden"
                class="sbtn"
              >
                <.icon name="hero-sun" class="size-4" />
              </button>
              <button
                type="button"
                phx-click="open_modal"
                phx-value-modal="connectors"
                aria-label="Connectors"
                class="sbtn"
              >
                <.icon name="hero-link" class="size-4" />
              </button>
            </nav>
            <div class="meta">
              <span class="v">P.A.I&nbsp;v{@app_version}</span>
              <span class="u">{@user_name}</span>
            </div>
          </div>
        </header>

        <%!-- Kiosk-only glanceable line: weather · next event · due reminders. Fetched via the tool
             layer in start_async (handle_info(:refresh_ambient, ...) below), refreshed every 5 min;
             @ambient is always assigned in mount/3 (even off-kiosk) so these reads never crash. --%>
        <div :if={@kiosk} id="ambient-strip" class="text-center text-sm opacity-60">
          {ambient_line(@ambient, @due)}
        </div>

        <section
          id="voice"
          phx-hook="Voice"
          phx-update="ignore"
          data-session-id={@session_id}
          data-user-token={@user_token}
          data-stt-sample-rate={@stt_sample_rate}
          data-tts-sample-rate={@tts_sample_rate}
          data-default-abi={to_string(@default_abi)}
          data-default-ptt={to_string(@default_ptt)}
          data-voice-activation={to_string(@voice_activation)}
          data-relock-seconds={@relock_seconds}
          data-assistant-name={@assistant_name}
          class="flex-1 min-h-0 flex flex-col gap-3"
        >
          <%!-- Orb (real, animated) in a machined bezel; the four controls sit as detents on the
               bezel's rim, clear of the sphere and its glow halos. The `.elbow` is a portrait-only
               light-pipe SVG bridging the bezel's glow down toward the transcript spine below (Task
               1's `--orb-glow` var, same as the bezel's rim arc) — hidden in kiosk's side-by-side
               layout, where there's no "down" to bridge. --%>
          <div
            id="orb-pane"
            class="relative mx-auto flex w-full max-w-[20rem] items-center justify-center"
          >
            <div class="bezel">
              <canvas id="orb-canvas"></canvas>
              <%!-- your live speech: the hook sets textContent + inline font-size --%>
              <div id="orb-caption"></div>

              <button
                id="power-btn"
                type="button"
                title="Power"
                aria-label="Power on/off"
                class="detent d-power"
              >
                <.icon name="hero-power" class="size-4" />
              </button>
              <button
                id="clear-convo"
                type="button"
                title="Clear conversation"
                aria-label="Clear conversation"
                phx-click="clear_conversation"
                data-confirm="Clear this conversation?"
                class="detent d-clear"
              >
                <.icon name="hero-trash" class="size-4" />
              </button>
              <label class="detent d-ptt" title="Push-to-talk mode">
                <input id="ptt-toggle" type="checkbox" class="sr-only" />
                <.icon name="hero-microphone" class="size-4" />
                <span class="dlabel">PTT</span>
              </label>
              <label class="detent d-abi" title="Allow barge-in">
                <input id="abi-toggle" type="checkbox" class="sr-only" />
                <.icon name="hero-hand-raised" class="size-4" />
                <span class="dlabel">ABI</span>
              </label>
            </div>
            <svg class="elbow" viewBox="0 0 100 30" preserveAspectRatio="none" aria-hidden="true">
              <path d="M50 0 C 50 18, 36 10, 36 30" />
            </svg>
          </div>

          <%!-- Transcript: the meridian — a glowing spine on the left rail, your amber turns rail-
               side to its left, Henry's green answers in the field to its right. `.spine` is a
               decorative SIBLING of #voice-log (not a child) inside the shared `.log` wrapper, so it
               stays put while the transcript scrolls past it; #voice-log stays the actual scroller
               the Voice hook appends turn lines into (id/role/aria-live unchanged). --%>
          <div class="log relative flex flex-1 min-h-0 flex-col">
            <div class="spine" aria-hidden="true"></div>
            <div
              id="voice-log"
              role="log"
              aria-live="polite"
              class="min-h-0 flex-1 overflow-y-auto"
            >
            </div>
          </div>

          <%!-- PTT hold tray: disabled (inert look, not hidden) when PTT mode is off; the hook
               removes `disabled` when PTT is enabled and toggles `.ptt-held` (amber slit/glow)
               while the button is held. --%>
          <button id="ptt-hold" type="button" disabled>
            <span class="slit" aria-hidden="true"></span>
            <span class="plabel">Hold to talk</span>
          </button>
        </section>

        <%!-- Bottom nav: slide-in modals, engraved stations mirroring the header's kiosk strip --%>
        <nav :if={!@kiosk} id="bottom-nav" aria-label="Panels">
          <button
            type="button"
            phx-click="open_modal"
            phx-value-modal="settings"
            class="nbtn"
            title="Settings"
          >
            <.icon name="hero-cog-6-tooth" class="size-5" /><span class="nlabel">Settings</span>
          </button>
          <button
            type="button"
            phx-click="open_modal"
            phx-value-modal="memory"
            class="nbtn"
            title="Memory"
          >
            <.icon name="hero-sparkles" class="size-5" /><span class="nlabel">Memory</span>
          </button>
          <button
            type="button"
            phx-click="open_modal"
            phx-value-modal="reminders"
            class="nbtn"
            title="Reminders"
          >
            <span :if={@due != []} data-due-dot="true" class="duedot"></span>
            <.icon name="hero-bell" class="size-5" /><span class="nlabel">Reminders</span>
          </button>
          <button
            type="button"
            phx-click="open_modal"
            phx-value-modal="lists"
            class="nbtn"
            title="Lists"
          >
            <.icon name="hero-clipboard-document-list" class="size-5" /><span class="nlabel">Lists</span>
          </button>
          <button
            type="button"
            phx-click="open_modal"
            phx-value-modal="garden"
            class="nbtn"
            title="Garden"
          >
            <.icon name="hero-sun" class="size-5" /><span class="nlabel">Garden</span>
          </button>
          <button
            type="button"
            phx-click="open_modal"
            phx-value-modal="connectors"
            class="nbtn"
            title="Connectors"
          >
            <.icon name="hero-link" class="size-5" /><span class="nlabel">Connectors</span>
          </button>
        </nav>
      </main>

      <.modal_panel open={@modal_open} modal={@modal}>
        <%= case @modal do %>
          <% :memory -> %>
            <.memory_panel facts={@facts} summary={@summary} assistant_name={@assistant_name} />
          <% :reminders -> %>
            <.reminders_panel due={@due} upcoming={@upcoming} />
          <% :books -> %>
            <.books_panel
              books={@books}
              current_book={@current_book}
              current_list={current_book_list(@lists, @current_book)}
              garden={@garden}
            />
          <% :lists -> %>
            <.lists_panel lists={@lists} />
          <% :garden -> %>
            <.garden_panel garden={@garden} />
          <% :connectors -> %>
            <.connectors_panel google_accounts={@google_accounts} grant={@grant} />
          <% :settings -> %>
            <.settings_panel
              current_user={@current_user}
              default_abi={@default_abi}
              default_ptt={@default_ptt}
              voice_activation={@voice_activation}
              briefing_time={@briefing_time}
              relock_seconds={@relock_seconds}
              app_version={@app_version}
              assistant_name={@assistant_name}
              present={@present}
              kiosk={@kiosk}
              switchable_users={@switchable_users}
            />
          <% :voice_lock -> %>
            <.voice_lock_panel
              vl={@voice_lock}
              user_token={@user_token}
              session_id={@session_id}
              stt_sample_rate={@stt_sample_rate}
            />
          <% _ -> %>
        <% end %>
      </.modal_panel>
    </div>
    """
  end
end
