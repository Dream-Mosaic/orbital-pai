defmodule AppWeb.ConversationLive do
  @moduledoc """
  The admin dashboard (`/`): a read-only monitor of the signed-in user's assistant (spec
  2026-09-26-web-admin-dashboard-design).

  Left, the live conversation mirrored from whichever device holds it: a status strip
  (session, policy phase, wake lock, bound device, who is connected) over the thread (saved
  history, then live rows). Right, an inspector with read-only tabs over the data the app's
  panels edit.

  It never joins `voice:` and never writes. It subscribes to `"conversation:<uid>"`, where
  `Conversation` broadcasts `{:mirror, event}`, so watching can never bind the conversation or
  touch its audio; every write lives on the panel channels the app uses. The only events are
  UI-local: `tab` and `show_book`.
  """
  use AppWeb, :live_view
  import AppWeb.DashboardPanels

  alias App.{Books, Garden, Lists, Memory, Reminders}
  alias App.Conversations.{Conversation, Sessions}
  alias App.Google.Accounts, as: GoogleAccounts
  alias AppWeb.Dashboard.Mirror

  # The voice channel's own history depth, so both surfaces open on the same tail.
  @history_turns 12
  # Rows kept in the DOM; a long session is a debugging aid, not an archive.
  @thread_limit -300
  @tabs ~w(reminders books memory connectors voice_lock settings)

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    sid = to_string(user.id)

    {mirror, watched} =
      if connected?(socket) do
        Phoenix.PubSub.subscribe(App.PubSub, "conversation:" <> sid)
        Memory.subscribe()

        for topic <-
              ~w(reminders:#{sid} reminders:household lists:#{sid} lists:household garden:#{sid} garden:household presence:voice voice_lock:#{sid}),
            do: Phoenix.PubSub.subscribe(App.PubSub, topic)

        watch_session(sid, Mirror.new())
      else
        {Mirror.new(), nil}
      end

    {:ok,
     socket
     |> assign(
       session_id: sid,
       page_title: "#{App.Config.default().name} · dashboard",
       assistant_name: App.Config.default().name,
       app_version: App.version(),
       tab: "reminders",
       book_key: nil,
       mirror: mirror,
       watched: watched,
       present: if(connected?(socket), do: present_list(), else: [])
     )
     |> stream_configure(:thread, dom_id: & &1.id)
     |> stream(:thread, Mirror.history_rows(Memory.recent_turns(user.id, @history_turns)))
     |> load_memory()
     |> load_reminders()
     |> load_books()
     |> load_google_accounts()
     |> load_voice_lock()}
  end

  @impl true
  def handle_event("tab", %{"tab" => tab}, socket) when tab in @tabs do
    # Settings and Voice Lock show fields of the user row, which the app changes without a
    # broadcast; reading it again on open keeps them honest.
    socket = socket |> refresh_user() |> load_voice_lock()
    {:noreply, assign(socket, tab: tab)}
  end

  def handle_event("tab", _params, socket), do: {:noreply, socket}

  def handle_event("show_book", %{"key" => key}, socket),
    do: {:noreply, assign(socket, book_key: key)}

  @impl true
  def handle_info({:mirror, :session_started}, socket) do
    {mirror, watched} = watch_session(socket.assigns.session_id, socket.assigns.mirror)
    {:noreply, assign(socket, mirror: mirror, watched: watched)}
  end

  def handle_info({:mirror, event}, socket) do
    {mirror, rows} = Mirror.apply_event(socket.assigns.mirror, event)

    {:noreply,
     Enum.reduce(
       rows,
       assign(socket, mirror: mirror),
       &stream_insert(&2, :thread, &1, limit: @thread_limit)
     )}
  end

  # Only the session being watched: a :DOWN from an older one can land after a newer one
  # started, and must not flip a live strip to "no session".
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{assigns: %{watched: pid}} = socket) do
    mirror = Mirror.put_snapshot(socket.assigns.mirror, nil)
    {:noreply, assign(socket, mirror: mirror, watched: nil)}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, socket), do: {:noreply, socket}

  def handle_info(:memory_updated, socket), do: {:noreply, load_memory(socket)}
  def handle_info({:reminder_due, _r}, socket), do: {:noreply, load_reminders(socket)}
  def handle_info({:reminders_changed}, socket), do: {:noreply, load_reminders(socket)}
  def handle_info({:lists_changed}, socket), do: {:noreply, load_books(socket)}
  def handle_info({:garden_changed}, socket), do: {:noreply, load_books(socket)}
  def handle_info({:voice_lock_changed}, socket), do: {:noreply, load_voice_lock(socket)}

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket),
    do: {:noreply, assign(socket, present: present_list())}

  # Look up the user's running conversation, monitor it so its end flips the strip, and seed
  # the strip from a snapshot. Returns the watched pid (nil when there is no session).
  defp watch_session(sid, mirror) do
    with {:ok, pid} <- Sessions.lookup(sid),
         {:ok, snap} <- safe_snapshot(pid) do
      Process.monitor(pid)
      {Mirror.put_snapshot(mirror, snap), pid}
    else
      _ -> {Mirror.put_snapshot(mirror, nil), nil}
    end
  end

  # The session can die between the lookup and the call.
  defp safe_snapshot(pid) do
    {:ok, Conversation.snapshot(pid)}
  catch
    :exit, _ -> :error
  end

  defp refresh_user(socket) do
    case App.Users.get(socket.assigns.current_user.id) do
      nil -> socket
      user -> assign(socket, current_user: user)
    end
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

  defp load_books(socket) do
    user = socket.assigns.current_user

    assign(socket,
      books: Books.for_user(user),
      default_book: Books.current(user),
      lists: Lists.list_visible(user.id),
      garden: Garden.garden(user.id)
    )
  end

  defp load_google_accounts(socket),
    do: assign(socket, google_accounts: GoogleAccounts.list(socket.assigns.current_user.id))

  defp load_voice_lock(socket) do
    user = socket.assigns.current_user

    assign(socket,
      voice_lock: %{
        mode: user.voice_lock_mode,
        enrolled_slots: App.Speaker.enrolled_slots(user.id),
        drops: App.Speaker.recent_drops(user.id),
        verifier_ready: App.Speaker.verifier().ready?()
      }
    )
  end

  # The book the inspector shows: the one picked here this visit, else the stored default.
  # A picked key that no longer resolves (list deleted elsewhere) falls back the same way.
  defp shown_book(books, key, default), do: Enum.find(books, &(&1.key == key)) || default

  defp tab_label("voice_lock"), do: "Voice Lock"
  defp tab_label(tab), do: String.capitalize(tab)

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :tabs, @tabs)

    ~H"""
    <div data-theme="dark" class="min-h-[100dvh] bg-base-300 text-base-content">
      <Layouts.flash_group flash={@flash} />

      <header class="flex items-center gap-3 border-b border-base-100 px-4 py-3">
        <span class="font-display text-lg font-semibold">{@assistant_name}</span>
        <span class="badge badge-ghost badge-sm">dashboard</span>
        <span class="ml-auto text-xs opacity-60">P.A.I v{@app_version}</span>
        <span class="text-sm">{@current_user.name}</span>
        <.link href={~p"/logout"} method="delete" class="btn btn-ghost btn-xs">Sign out</.link>
      </header>

      <main class="grid grid-cols-1 gap-4 p-4 md:grid-cols-[minmax(0,1fr)_20rem] xl:grid-cols-[minmax(0,1fr)_26rem]">
        <section
          id="live"
          class="flex min-h-[70dvh] min-w-0 flex-col gap-3 rounded-box bg-base-200 p-4 md:h-[calc(100dvh-5rem)]"
        >
          <.status_strip status={@mirror.status} present={@present} />
          <div
            id="thread"
            phx-update="stream"
            class="flex-1 space-y-2 overflow-x-hidden overflow-y-auto"
          >
            <div :for={{dom_id, row} <- @streams.thread} id={dom_id}>
              <.thread_row row={row} assistant_name={@assistant_name} />
            </div>
          </div>
          <p
            :if={@mirror.caption}
            id="caption"
            class="text-sm italic opacity-60 [overflow-wrap:anywhere]"
          >
            {@mirror.caption}
          </p>
        </section>

        <aside id="inspector" class="min-w-0 rounded-box bg-base-200 p-4">
          <div role="tablist" class="tabs tabs-box tabs-sm flex-wrap">
            <button
              :for={t <- @tabs}
              type="button"
              role="tab"
              phx-click="tab"
              phx-value-tab={t}
              class={["tab", @tab == t && "tab-active"]}
            >
              {tab_label(t)}
            </button>
          </div>
          <div class="mt-4">
            <.reminders_panel :if={@tab == "reminders"} due={@due} upcoming={@upcoming} />
            <.books_panel
              :if={@tab == "books"}
              books={@books}
              current_book={shown_book(@books, @book_key, @default_book)}
              lists={@lists}
              garden={@garden}
            />
            <.memory_panel :if={@tab == "memory"} facts={@facts} summary={@summary} />
            <.connectors_panel :if={@tab == "connectors"} google_accounts={@google_accounts} />
            <.voice_lock_panel :if={@tab == "voice_lock"} vl={@voice_lock} />
            <.settings_panel :if={@tab == "settings"} user={@current_user} app_version={@app_version} />
          </div>
        </aside>
      </main>
    </div>
    """
  end
end
