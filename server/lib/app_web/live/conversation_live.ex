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

  defp tab_icon("reminders"), do: "hero-bell-micro"
  defp tab_icon("books"), do: "hero-book-open-micro"
  defp tab_icon("memory"), do: "hero-light-bulb-micro"
  defp tab_icon("connectors"), do: "hero-link-micro"
  defp tab_icon("voice_lock"), do: "hero-finger-print-micro"
  defp tab_icon("settings"), do: "hero-cog-6-tooth-micro"

  # Desktop is a fixed-height shell: the header is a row of its own and the grid takes the
  # rest (`flex-1 min-h-0`), so the thread and the inspector each scroll inside their column
  # without any estimate of the header's height. Below `lg` the page scrolls instead and the
  # live column takes most of a screen, so the inspector is one swipe below it.
  #
  # The thread's scroller is `flex-col-reverse` around a single child, which anchors it to
  # the bottom: the newest row stays in view as the answer grows, with no JS hook.
  @impl true
  def render(assigns) do
    assigns = assign(assigns, :tabs, @tabs)

    ~H"""
    <div
      data-theme="dark"
      class="dashboard flex min-h-dvh flex-col bg-base-300 text-base-content lg:h-dvh"
    >
      <Layouts.flash_group flash={@flash} />

      <header class="flex h-12 shrink-0 items-center gap-3 border-b border-base-content/[0.07] px-4">
        <span class="font-display text-[17px] font-semibold tracking-tight">
          {@assistant_name}
        </span>
        <span class="hidden text-xs text-base-content/50 sm:inline">dashboard</span>
        <div class="ms-auto flex min-w-0 items-center gap-3">
          <span class="font-mono text-[11px] text-base-content/45">P.A.I v{@app_version}</span>
          <span class="truncate text-sm text-base-content/80">{@current_user.name}</span>
          <.link href={~p"/logout"} method="delete" class="btn btn-ghost btn-xs">Sign out</.link>
        </div>
      </header>

      <main class="grid flex-1 grid-cols-1 gap-3 p-3 lg:min-h-0 lg:grid-cols-[minmax(0,1fr)_22rem] lg:grid-rows-[minmax(0,1fr)] xl:grid-cols-[minmax(0,1fr)_26rem] 2xl:grid-cols-[minmax(0,1fr)_30rem]">
        <section
          id="live"
          data-phase={@mirror.status.phase}
          class="flex h-[82dvh] min-h-[26rem] min-w-0 flex-col rounded-box border border-base-content/[0.06] bg-base-200 lg:h-auto lg:min-h-0"
        >
          <div class="shrink-0 border-b border-base-content/[0.07] px-4 py-3">
            <.status_strip status={@mirror.status} present={@present} />
          </div>

          <div class="meridian @container relative mx-4 flex min-h-0 flex-1 flex-col">
            <div
              aria-hidden="true"
              class="meridian-spine pointer-events-none absolute inset-y-0 left-[var(--rail)] w-[1.5px]"
            >
            </div>
            <div class="flex min-h-0 flex-1 flex-col-reverse overflow-y-auto overscroll-contain pt-1 pr-2 pb-4 [mask-image:linear-gradient(to_bottom,transparent,#000_1.25rem)]">
              <div id="thread" phx-update="stream">
                <div
                  id="thread-empty"
                  class="relative mt-6 hidden pl-[calc(var(--rail)+1.25rem)] only:block"
                >
                  <span
                    aria-hidden="true"
                    class="absolute top-[4.5px] left-[calc(var(--rail)-2.75px)] size-[7px] rounded-full border border-base-content/40 bg-base-200"
                  ></span>
                  <p class="text-[11px] font-semibold leading-4 tracking-wide text-base-content/45">
                    quiet
                  </p>
                  <p class="mt-1 max-w-[52ch] text-sm leading-relaxed text-base-content/60">
                    No turns yet. Talk to {@assistant_name} on any device and the conversation
                    streams in here as it happens; this page only watches.
                  </p>
                </div>
                <div :for={{dom_id, row} <- @streams.thread} id={dom_id}>
                  <.thread_row row={row} assistant_name={@assistant_name} />
                </div>
              </div>
            </div>
            <div
              :if={@mirror.caption}
              id="caption"
              class="relative shrink-0 border-t border-dashed border-you/15 pt-2.5 pb-3 pl-[calc(var(--rail)+1.25rem)] [overflow-wrap:anywhere] @xl:border-t-0 @xl:w-[calc(var(--rail)-1.25rem)] @xl:pl-0 @xl:text-right"
            >
              <span
                aria-hidden="true"
                class="absolute top-[calc(0.625rem+4.5px)] left-[calc(var(--rail)-2.75px)] size-[7px] rounded-full border border-you motion-safe:animate-pulse"
              ></span>
              <p class="text-[11px] font-semibold leading-4 tracking-wide text-you/70">hearing</p>
              <p class="mt-1 text-sm italic leading-relaxed text-you-body/75">{@mirror.caption}</p>
            </div>
          </div>
        </section>

        <aside
          id="inspector"
          class="flex min-w-0 flex-col rounded-box border border-base-content/[0.06] bg-base-200 lg:min-h-0"
        >
          <div
            role="tablist"
            class="tabs tabs-box tabs-sm m-3 mb-0 grid shrink-0 grid-cols-3 gap-1 sm:grid-cols-6 lg:grid-cols-3"
          >
            <button
              :for={t <- @tabs}
              type="button"
              role="tab"
              aria-selected={to_string(@tab == t)}
              phx-click="tab"
              phx-value-tab={t}
              class={["tab min-w-0 flex-nowrap gap-1.5 px-1.5 text-[13px]", @tab == t && "tab-active"]}
            >
              <.icon name={tab_icon(t)} class="size-3.5 shrink-0 opacity-70" />
              <span class="truncate">{tab_label(t)}</span>
            </button>
          </div>
          <div class="px-4 pt-4 pb-6 lg:min-h-0 lg:flex-1 lg:overflow-y-auto">
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
