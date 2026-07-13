defmodule AppWeb.VoiceModals do
  @moduledoc "Slide-in modal shell + the four content panels for the voice screen."
  use AppWeb, :html

  alias App.Google.Connectors

  @doc """
  Renders the slide-in right-side drawer.

  `open` (boolean) drives ONLY the transition classes + `data-modal-open`, so the
  drawer can slide closed while still showing its last content. `modal` (atom, may
  be stale while closing) drives the title and is what callers should `case` on for
  the panel content — it is intentionally NOT reset to nil on close.
  """
  attr :open, :boolean, default: false
  attr :modal, :atom, default: nil
  slot :inner_block, required: true

  def modal_panel(assigns) do
    ~H"""
    <div
      id="voice-modal"
      data-modal-open={to_string(@open)}
      phx-window-keydown="close_modal"
      phx-key="Escape"
      class={[
        "fixed inset-0 z-50",
        (!@open && "pointer-events-none") || "pointer-events-auto"
      ]}
    >
      <div
        class={[
          "absolute inset-0 bg-black/40 transition-opacity duration-300",
          (!@open && "opacity-0") || "opacity-100"
        ]}
        phx-click="close_modal"
        aria-hidden="true"
      >
      </div>
      <div class={[
        "absolute inset-y-0 right-0 flex w-full max-w-[24rem] flex-col bg-base-100 shadow-2xl transition-transform duration-300",
        (!@open && "translate-x-full") || "translate-x-0"
      ]}>
        <div class="absolute inset-y-0 left-0 flex items-center">
          <div class="ml-0.5 h-12 w-1.5 rounded-r bg-base-300"></div>
        </div>
        <header class="flex items-center justify-between border-b border-base-300 p-4">
          <h2 class="text-lg font-semibold">{modal_title(@modal)}</h2>
          <button phx-click="close_modal" class="btn btn-ghost btn-circle btn-sm" aria-label="Close">
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </header>
        <div class="flex-1 overflow-y-auto p-4">
          {render_slot(@inner_block)}
        </div>
      </div>
    </div>
    """
  end

  defp modal_title(:memory), do: "Memory"
  defp modal_title(:reminders), do: "Reminders"
  defp modal_title(:lists), do: "Lists"
  defp modal_title(:garden), do: "Garden"
  defp modal_title(:connectors), do: "Connectors"
  defp modal_title(:settings), do: "Settings"
  defp modal_title(:voice_lock), do: "Voice Lock"
  defp modal_title(:books), do: "Books"
  defp modal_title(_), do: ""

  @doc "Reminders modal contents: due (needs attention) + upcoming lists, dismiss buttons, and a cadence badge on recurring rows (the ✕ on a recurring row cancels the whole series — the row IS the series)."
  attr :due, :list, required: true
  attr :upcoming, :list, required: true

  def reminders_panel(assigns) do
    ~H"""
    <div class="space-y-3">
      <div :if={@due != []} class="space-y-1">
        <label class="text-xs opacity-60">Needs your attention</label>
        <ul class="space-y-1">
          <li :for={r <- @due} class="flex items-center gap-2">
            <span class="badge badge-sm badge-warning">due</span>
            <span :if={r.kind == "followup"} class="badge badge-sm badge-ghost">follow-up</span>
            <span :if={r.household} class="badge badge-sm badge-accent">shared</span>
            <span :if={r.recurrence} class="badge badge-sm badge-info">
              {fmt_recurrence(r.recurrence, r.due_at)}
            </span>
            <span class="flex-1">{r.body}</span>
            <span class="text-xs opacity-60 font-mono">{fmt_due(r.due_at)}</span>
            <button
              class="btn btn-ghost btn-xs"
              phx-click="ack_reminder"
              phx-value-id={r.id}
              aria-label="acknowledge reminder"
            >
              ✓
            </button>
            <button
              class="btn btn-ghost btn-xs"
              phx-click="dismiss_reminder"
              phx-value-id={r.id}
              aria-label="dismiss reminder"
            >
              ✕
            </button>
          </li>
        </ul>
      </div>

      <div class="space-y-1">
        <label class="text-xs opacity-60">Upcoming</label>
        <ul class="space-y-1">
          <li :for={r <- @upcoming} class="flex items-center gap-2">
            <span :if={r.kind == "followup"} class="badge badge-sm badge-ghost">follow-up</span>
            <span :if={r.household} class="badge badge-sm badge-accent">shared</span>
            <span :if={r.recurrence} class="badge badge-sm badge-info">
              {fmt_recurrence(r.recurrence, r.due_at)}
            </span>
            <span class="flex-1">{r.body}</span>
            <span class="text-xs opacity-60 font-mono">{fmt_due(r.due_at)}</span>
            <button
              class="btn btn-ghost btn-xs"
              phx-click="dismiss_reminder"
              phx-value-id={r.id}
              aria-label={(r.recurrence && "cancel repeating reminder") || "delete reminder"}
            >
              ✕
            </button>
          </li>
          <li :if={@upcoming == []} class="text-sm opacity-50">Nothing scheduled.</li>
        </ul>
      </div>
    </div>
    """
  end

  # due_at is stored UTC; shift to the configured local timezone for display.
  @doc false
  def fmt_due(%DateTime{} = dt) do
    local = DateTime.shift_zone!(dt, App.Config.default().timezone)
    Calendar.strftime(local, "%b %-d %-I:%M%P")
  end

  # Humanize a recurrence rule for the cadence badge: "every Tue", "every 3 days",
  # "monthly on the 1st", "yearly". Day-of-month/weekday fall back to due_at, rendered in the
  # configured local timezone (same as fmt_due/1). nil rule (one-shot) → nil (no badge).
  @doc false
  def fmt_recurrence(nil, _due_at), do: nil

  def fmt_recurrence(%{"freq" => freq} = rule, %DateTime{} = due_at) do
    interval = rule["interval"] || 1
    local = DateTime.shift_zone!(due_at, App.Config.default().timezone)

    case freq do
      "daily" ->
        if interval == 1, do: "daily", else: "every #{interval} days"

      "weekly" ->
        days = byday_label(rule, local)
        if interval == 1, do: "every #{days}", else: "every #{interval} wks: #{days}"

      "monthly" ->
        day = "the #{ordinal(local.day)}"
        if interval == 1, do: "monthly on #{day}", else: "every #{interval} months on #{day}"

      "yearly" ->
        if interval == 1, do: "yearly", else: "every #{interval} years"

      _ ->
        "repeats"
    end
  end

  def fmt_recurrence(_rule, _due_at), do: "repeats"

  defp byday_label(%{"byday" => [_ | _] = codes}, _local),
    do: codes |> Enum.map(&String.capitalize/1) |> Enum.join(", ")

  defp byday_label(_rule, local), do: Calendar.strftime(local, "%a")

  defp ordinal(n) when n in [1, 21, 31], do: "#{n}st"
  defp ordinal(n) when n in [2, 22], do: "#{n}nd"
  defp ordinal(n) when n in [3, 23], do: "#{n}rd"
  defp ordinal(n), do: "#{n}th"

  @doc """
  Lists modal contents: the user's visible lists (own + household), each with check-off items, an
  add-item field, a clear-done button, and a delete-list button. Household lists get the shared
  badge (reuses the reminders panel's accent-badge style).
  """
  attr :lists, :list, required: true

  def lists_panel(assigns) do
    ~H"""
    <div class="space-y-4">
      <div :for={list <- @lists} class="space-y-2 rounded-box border border-base-300 p-3">
        <div class="flex items-center gap-2">
          <span class="flex-1 font-semibold">{list.name}</span>
          <span :if={list.household} class="badge badge-sm badge-accent">shared</span>
          <button
            :if={done_count(list) > 0}
            class="btn btn-ghost btn-xs"
            phx-click="clear_list_checked"
            phx-value-id={list.id}
          >
            Clear done
          </button>
          <button
            class="btn btn-ghost btn-xs"
            phx-click="delete_list"
            phx-value-id={list.id}
            data-confirm={"Delete the #{list.name} list?"}
            aria-label="delete list"
          >
            ✕
          </button>
        </div>

        <ul class="space-y-1">
          <li :for={item <- sorted_items(list)} class="flex items-center gap-2">
            <input
              type="checkbox"
              class="checkbox checkbox-xs"
              checked={item.checked_at != nil}
              phx-click="toggle_list_item"
              phx-value-id={item.id}
            />
            <span class={["flex-1", item.checked_at && "line-through opacity-50"]}>{item.text}</span>
          </li>
          <li :if={list.items == []} class="text-sm opacity-50">Nothing on it yet.</li>
        </ul>

        <form phx-submit="add_list_item" class="flex gap-2">
          <input type="hidden" name="list_id" value={list.id} />
          <input
            type="text"
            name="text"
            value=""
            placeholder={"Add to #{list.name}…"}
            class="input input-bordered input-sm flex-1"
          />
          <button class="btn btn-sm" type="submit">Add</button>
        </form>
      </div>

      <p :if={@lists == []} class="text-sm opacity-50">No lists yet — just ask to add something.</p>
    </div>
    """
  end

  defp sorted_items(list), do: Enum.sort_by(list.items, &(&1.checked_at != nil))
  defp done_count(list), do: Enum.count(list.items, &(&1.checked_at != nil))

  @doc """
  Garden modal contents: Active plant cards (name, meta line, latest note expandable to the
  full check-in log, an add-note field, an Archive button) + a collapsible Past Seasons
  section grouped by season, read-only with a Revive action. Household plants get the shared
  badge (same accent-badge as lists/reminders). Season close-out is voice-only in v1.
  """
  attr :garden, :map, required: true

  def garden_panel(assigns) do
    ~H"""
    <div class="space-y-4">
      <div
        :for={plant <- @garden.active}
        class="space-y-2 rounded-box border border-base-300 p-3"
      >
        <div class="flex items-center gap-2">
          <span class="flex-1 font-semibold">{plant.name}</span>
          <span :if={plant.household} class="badge badge-sm badge-accent">shared</span>
          <button
            class="btn btn-ghost btn-xs"
            phx-click="archive_plant"
            phx-value-id={plant.id}
            data-confirm={"Move #{plant.name} to past seasons?"}
          >
            Archive
          </button>
        </div>

        <p :if={plant_meta(plant) != ""} class="text-xs opacity-60">{plant_meta(plant)}</p>

        <details :if={plant.notes != []} class="text-sm">
          <summary class="cursor-pointer opacity-70">{latest_note_line(plant)}</summary>
          <ul class="mt-1 space-y-1">
            <li :for={note <- plant.notes} class="flex items-center gap-2">
              <span class="flex-1">{note.body}</span>
              <span class="text-xs opacity-60 font-mono">{fmt_noted(note)}</span>
            </li>
          </ul>
        </details>

        <form phx-submit="add_plant_note" class="flex gap-2">
          <input type="hidden" name="plant_id" value={plant.id} />
          <input
            type="text"
            name="body"
            value=""
            placeholder={"Check in on #{plant.name}…"}
            class="input input-bordered input-sm flex-1"
          />
          <button class="btn btn-sm" type="submit">Note</button>
        </form>
      </div>

      <p :if={@garden.active == []} class="text-sm opacity-50">
        Nothing growing yet — just say what you planted.
      </p>

      <details :if={@garden.archived_by_season != %{}}>
        <summary class="cursor-pointer text-sm font-semibold opacity-70">Past seasons</summary>
        <div
          :for={{season, plants} <- seasons_desc(@garden.archived_by_season)}
          class="mt-2 space-y-1"
        >
          <label class="text-xs opacity-60">{season}</label>
          <ul class="space-y-1">
            <li :for={plant <- plants} class="flex items-center gap-2">
              <span class="flex-1 opacity-70">{plant.name}</span>
              <span :if={plant.household} class="badge badge-sm badge-accent">shared</span>
              <button class="btn btn-ghost btn-xs" phx-click="revive_plant" phx-value-id={plant.id}>
                Revive
              </button>
            </li>
          </ul>
        </div>
      </details>
    </div>
    """
  end

  # most recent season first ("Summer 2026" and "2026" sort fine as strings within a year;
  # exact cross-format ordering is cosmetic)
  defp seasons_desc(by_season), do: Enum.sort_by(by_season, fn {season, _} -> season end, :desc)

  # "Roma · back bed · 5 plants · planted Jul 11" — only the fields that exist.
  defp plant_meta(plant) do
    [
      plant.species,
      plant.location,
      plant.count && "#{plant.count} plants",
      plant.planted_on && "planted #{Calendar.strftime(plant.planted_on, "%b %-d")}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  # notes come preloaded oldest-first (Garden.garden/1), so the latest is the last.
  defp latest_note_line(plant) do
    case List.last(plant.notes) do
      nil -> "Notes"
      note -> note.body
    end
  end

  defp fmt_noted(%{noted_on: %Date{} = d}), do: Calendar.strftime(d, "%b %-d")
  defp fmt_noted(%{inserted_at: dt}), do: Calendar.strftime(dt, "%b %-d")

  @doc """
  Books modal contents: a remembered picker — a header row showing the current book's icon,
  label, and a type-aware "Clear ↻" (list → empties items but keeps the list; garden → closes
  out the season) — plus a "Switch book" disclosure listing every book flat, with "➕ New
  list…" at the bottom. The body renders the CURRENT book's existing panel UNCHANGED:
  `lists_panel/1` given a one-element list (`current_list`) for a `:list` book, or
  `garden_panel/1` for the `:garden` book. `current_list` is nil when the remembered list was
  deleted elsewhere between loads (rare — the caller's `load_books/1` already falls back on a
  stale key, but a delete from another session can still race a render) — the body then shows a
  short nudge instead of crashing.
  """
  attr :books, :list, required: true
  attr :current_book, :map, required: true
  attr :current_list, :map, default: nil
  attr :garden, :map, required: true

  def books_panel(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="flex items-center gap-2 rounded-box border border-base-300 p-3">
        <.icon name={@current_book.icon} class="size-4" />
        <span class="flex-1 font-semibold">{@current_book.label}</span>
        <button
          type="button"
          phx-click="clear_book"
          data-confirm={clear_confirm_text(@current_book)}
          class="btn btn-ghost btn-xs"
          aria-label="clear book"
        >
          Clear ↻
        </button>
      </div>

      <details class="rounded-box border border-base-300">
        <summary class="cursor-pointer p-3 text-sm opacity-70">Switch book</summary>
        <ul class="space-y-1 border-t border-base-300 p-2">
          <li :for={book <- @books}>
            <button
              type="button"
              phx-click="select_book"
              phx-value-key={book.key}
              class={[
                "btn btn-ghost btn-sm w-full justify-start gap-2",
                book.key == @current_book.key && "btn-active"
              ]}
            >
              <.icon name={book.icon} class="size-4" /> {book.label}
            </button>
          </li>
          <li>
            <details>
              <summary class="btn btn-ghost btn-sm w-full justify-start cursor-pointer">
                ➕ New list…
              </summary>
              <form phx-submit="new_list" class="flex gap-2 p-2">
                <input
                  type="text"
                  name="name"
                  value=""
                  placeholder="Name your list…"
                  class="input input-bordered input-sm flex-1"
                />
                <button class="btn btn-sm" type="submit">Create</button>
              </form>
            </details>
          </li>
        </ul>
      </details>

      <.lists_panel :if={@current_book.kind == :list and @current_list} lists={[@current_list]} />
      <.garden_panel :if={@current_book.kind == :garden} garden={@garden} />
      <p :if={@current_book.kind == :list and !@current_list} class="text-sm opacity-50">
        That list is gone — pick another book above.
      </p>
    </div>
    """
  end

  defp clear_confirm_text(%{kind: :garden}),
    do: "Close out this season? Active plants move to Past seasons — nothing is deleted."

  defp clear_confirm_text(%{label: label}),
    do: "Clear everything off #{label}? The list stays, just empty."

  @doc "Connectors modal contents: Google connection rows + inline grant step when @grant is set."
  attr :google_accounts, :list, required: true
  attr :grant, :map, default: nil

  def connectors_panel(assigns) do
    ~H"""
    <div class="space-y-3">
      <ul class="space-y-1">
        <li
          :for={{conn, a} <- connection_rows(@google_accounts)}
          class="flex items-center gap-2 text-sm"
        >
          <span class="flex-1">
            {Connectors.label(conn)} <span class="opacity-60">({a.email})</span>
          </span>

          <span :if={connector_multi?(@google_accounts, conn)} class="flex items-center gap-1">
            <span :if={a.is_default} class="badge badge-sm badge-primary">default</span>
            <button
              :if={!a.is_default}
              class="btn btn-ghost btn-xs"
              phx-click="set_default_google"
              phx-value-id={a.id}
            >
              Set default
            </button>
          </span>

          <span class="badge badge-sm badge-ghost">{Connectors.access(a, conn)}</span>

          <button
            class="btn btn-ghost btn-xs"
            phx-click="disconnect_connection"
            phx-value-account={a.id}
            phx-value-connector={conn}
            aria-label="disconnect connection"
          >
            Disconnect
          </button>
        </li>
        <li :if={connection_rows(@google_accounts) == []} class="text-sm opacity-50">
          No connections.
        </li>
      </ul>

      <button class="btn btn-sm" phx-click="grant_open">+ Connect account</button>

      <div :if={@grant} class="rounded-box border border-base-300 p-3 space-y-3">
        <h3 class="font-semibold text-sm">Add a connection</h3>

        <form id="grant-form" phx-change="grant_change" phx-submit="grant_submit" class="space-y-3">
          <label class="form-control">
            <span class="label-text text-xs">Connector</span>
            <select name="connector" class="select select-bordered select-sm">
              <option :for={c <- Connectors.all()} value={c} selected={@grant.connector == c}>
                {Connectors.label(c)}
              </option>
            </select>
          </label>

          <label class="form-control">
            <span class="label-text text-xs">Account</span>
            <select name="account" class="select select-bordered select-sm">
              <option value="new" selected={@grant.account_id == :new}>New Google account</option>
              <option
                :for={a <- @google_accounts}
                value={a.id}
                selected={@grant.account_id == a.id}
              >
                {a.email}
              </option>
            </select>
          </label>

          <div class="flex items-center gap-3">
            <span class="label-text text-xs">Access</span>
            <label
              :for={lvl <- Connectors.access_levels(@grant.connector)}
              class="flex items-center gap-1 text-sm"
            >
              <input
                type="radio"
                name="level"
                value={lvl}
                checked={@grant.level == lvl}
                class="radio radio-xs"
              />
              {lvl}
            </label>
          </div>

          <div class="flex justify-end gap-2">
            <button type="button" class="btn btn-ghost btn-sm" phx-click="grant_cancel">
              Cancel
            </button>
            <button
              type="submit"
              class="btn btn-primary btn-sm"
              disabled={grant_noop?(@grant)}
            >
              Grant
            </button>
          </div>
        </form>
      </div>
    </div>
    """
  end

  defp connection_rows(accounts) do
    for(a <- accounts, conn <- Connectors.granted(a), do: {conn, a})
    |> Enum.sort_by(fn {conn, a} -> {Connectors.label(conn), a.email} end)
  end

  defp connector_multi?(accounts, connector),
    do: Enum.count(accounts, &(Connectors.access(&1, connector) != :none)) >= 2

  defp grant_noop?(%{account_id: :new, level: :none}), do: true
  defp grant_noop?(_grant), do: false

  @doc "Settings modal: account, voice prefs, danger zone, about."
  attr :current_user, :map, required: true
  attr :default_abi, :boolean, default: false
  attr :default_ptt, :boolean, default: false
  attr :voice_activation, :boolean, default: false
  attr :briefing_time, :string, default: nil
  attr :relock_seconds, :integer, default: 15
  attr :app_version, :string, required: true
  attr :assistant_name, :string, required: true
  attr :present, :list, default: []
  attr :kiosk, :boolean, default: false
  attr :switchable_users, :list, default: []

  def settings_panel(assigns) do
    ~H"""
    <div class="space-y-6">
      <section class="space-y-1">
        <h3 class="text-sm font-semibold opacity-70">Account</h3>
        <p>{@current_user.name}</p>
        <p class="text-sm opacity-60">{@current_user.email}</p>
        <.link href={~p"/logout"} method="delete" class="btn btn-sm btn-outline">Sign out</.link>
      </section>

      <section class="space-y-1">
        <h3 class="text-sm font-semibold opacity-70">Active now</h3>
        <p :for={p <- @present} class="text-sm">
          {p.name} <span class="opacity-60">({if p.kiosk, do: "wall", else: "phone"})</span>
        </p>
        <p :if={@present == []} class="text-sm opacity-50">No one connected.</p>
      </section>

      <section class="space-y-2">
        <h3 class="text-sm font-semibold opacity-70">Voice</h3>
        <label class="flex cursor-pointer items-center justify-between">
          Default ABI (allow barge-in)
          <input
            type="checkbox"
            class="toggle toggle-sm"
            checked={@default_abi}
            phx-click="update_pref"
            phx-value-pref="default_abi"
          />
        </label>
        <label class="flex cursor-pointer items-center justify-between">
          Default PTT (push-to-talk)
          <input
            type="checkbox"
            class="toggle toggle-sm"
            checked={@default_ptt}
            phx-click="update_pref"
            phx-value-pref="default_ptt"
          />
        </label>
        <label class="flex cursor-pointer items-center justify-between">
          Voice activation (say the wake word; wall only)
          <input
            type="checkbox"
            class="toggle toggle-sm"
            checked={@voice_activation}
            phx-click="update_pref"
            phx-value-pref="voice_activation"
          />
        </label>
        <label class="flex cursor-pointer items-center justify-between">
          Morning briefing (spoken your first turn that morning)
          <input
            type="checkbox"
            id="settings-briefing-toggle"
            class="toggle toggle-sm"
            checked={@briefing_time != nil}
            phx-click="toggle_briefing"
          />
        </label>
        <form :if={@briefing_time} id="briefing-time-form" phx-change="set_briefing_time">
          <div class="flex items-center justify-between">
            <span>Briefing time</span>
            <input
              type="time"
              id="settings-briefing-time"
              name="briefing_time"
              value={@briefing_time}
              class="input input-sm"
            />
          </div>
        </form>
        <form id="lockdown-form" phx-change="set_relock" class="space-y-1">
          <div class="flex items-center justify-between">
            <span>Lockdown timeout (wall)</span>
            <span class="opacity-70">{@relock_seconds}s</span>
          </div>
          <input
            type="range"
            min="10"
            max="30"
            step="1"
            name="seconds"
            value={@relock_seconds}
            phx-debounce="200"
            class="range range-sm w-full"
          />
        </form>
      </section>

      <section :if={@kiosk and @switchable_users != []} class="space-y-2">
        <h3 class="text-sm font-semibold opacity-70">Switch user</h3>
        <form :for={u <- @switchable_users} action="/kiosk/switch_user" method="post">
          <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
          <input type="hidden" name="user_id" value={u.id} />
          <button class="btn btn-sm btn-outline w-full">
            {u.name} <span class="opacity-60">({u.email})</span>
          </button>
        </form>
      </section>

      <section class="space-y-2">
        <h3 class="text-sm font-semibold text-error">Danger zone</h3>
        <button
          id="settings-clear-convo"
          phx-click="clear_conversation"
          data-confirm="Clear this conversation?"
          class="btn btn-sm btn-outline btn-error w-full"
        >Clear conversation</button>
        <button
          phx-click="forget_me"
          data-confirm={"Forget everything #{@assistant_name} knows about you?"}
          class="btn btn-sm btn-error w-full"
        >Wipe memory</button>
      </section>

      <section class="space-y-1 text-sm">
        <h3 class="text-sm font-semibold opacity-70">About</h3>
        <p class="opacity-60">P.A.I v{@app_version}</p>
      </section>

      <section class="space-y-1">
        <button
          type="button"
          phx-click="open_modal"
          phx-value-modal="voice_lock"
          class="btn btn-ghost btn-sm w-full justify-between"
        >
          Voice Lock <span class="opacity-60">→</span>
        </button>
      </section>
    </div>
    """
  end

  @voice_lock_prompts [
    {1,
     "Hey Remi, this is my normal speaking voice. I'm going to ask about the weather, my calendar, reminders, and the grocery list, just like I do every day."},
    {2,
     "The quick brown fox jumps over the lazy dog, while the five boxing wizards jump quickly over the frozen river behind our house."},
    {3,
     "What's on my calendar tomorrow morning? Remind me to water the garden at six, and add milk, eggs, and coffee to the groceries, please."}
  ]

  @doc "Voice Lock panel: tri-state mode, guided enrollment (3 prompts), recent-drops audit list."
  attr :vl, :map, required: true
  attr :user_token, :string, required: true
  attr :session_id, :string, required: true
  attr :stt_sample_rate, :integer, required: true

  def voice_lock_panel(assigns) do
    assigns = assign(assigns, :prompts, @voice_lock_prompts)

    ~H"""
    <div
      id="voice-enroll"
      phx-hook="VoiceEnroll"
      data-token={@user_token}
      data-user={@session_id}
      data-rate={@stt_sample_rate}
      class="space-y-4"
    >
      <p :if={!@vl.verifier_ready} class="alert alert-warning text-sm">
        Speaker model unavailable — Voice Lock is failing open (everything passes).
      </p>

      <div class="space-y-1">
        <label class="text-xs opacity-60">Mode</label>
        <div class="join w-full">
          <button
            :for={m <- ~w(off shadow enforce)}
            type="button"
            phx-click="voice_lock_mode"
            phx-value-mode={m}
            class={["btn btn-sm join-item flex-1", (@vl.mode == m && "btn-primary") || "btn-ghost"]}
          >
            {String.capitalize(m)}
          </button>
        </div>
        <p class="text-xs opacity-60">
          Shadow scores every turn but blocks nothing — live with it a few days, then enforce.
        </p>
      </div>

      <div class="space-y-2">
        <label class="text-xs opacity-60">Enrollment — read each prompt aloud (~10s each)</label>
        <div :for={{slot, text} <- @prompts} class="rounded-lg border border-base-300 p-3 space-y-2">
          <p class="text-sm">{text}</p>
          <div class="flex items-center gap-2">
            <button
              type="button"
              phx-click="enroll_record"
              phx-value-slot={slot}
              class="btn btn-xs btn-outline"
              disabled={@vl.recording_slot != nil}
            >
              {(slot in @vl.enrolled_slots && "Re-record") || "Record"}
            </button>
            <span :if={@vl.recording_slot == slot} class="text-xs text-warning">recording…</span>
            <span
              :if={slot in @vl.enrolled_slots and @vl.recording_slot != slot}
              class="text-xs text-success"
            >✓ enrolled</span>
            <span
              :if={@vl.enroll_error && elem(@vl.enroll_error, 0) == slot}
              class="text-xs text-error"
            >
              {elem(@vl.enroll_error, 1)}
            </span>
          </div>
        </div>
      </div>

      <div class="space-y-1">
        <label class="text-xs opacity-60">Recently filtered</label>
        <ul class="space-y-1">
          <li :for={e <- @vl.drops} class="text-xs flex items-center gap-2">
            <span class="badge badge-xs badge-ghost">{e.decision}</span>
            <span class="flex-1 truncate opacity-80">{e.transcript}</span>
            <span class="font-mono opacity-60">{e.score && Float.round(e.score, 2)}</span>
          </li>
          <li :if={@vl.drops == []} class="text-xs opacity-50">Nothing filtered yet.</li>
        </ul>
      </div>
    </div>
    """
  end

  @doc "Memory modal contents: profile facts, rolling summary, and a wipe-all button."
  attr :facts, :list, required: true
  attr :summary, :string, default: ""
  attr :assistant_name, :string, required: true

  def memory_panel(assigns) do
    ~H"""
    <div class="space-y-4">
      <form id="summary-form" phx-submit="save_summary" class="space-y-2">
        <label class="text-xs opacity-60">Rolling summary</label>
        <textarea
          name="summary"
          rows="3"
          class="textarea textarea-bordered w-full"
          placeholder="(nothing yet — we'll build this as we talk)"
        >{@summary}</textarea>
        <button class="btn btn-sm" type="submit">Save summary</button>
      </form>

      <div class="space-y-2">
        <label class="text-xs opacity-60">Profile facts</label>
        <ul class="space-y-1">
          <li :for={fact <- @facts} class="flex items-center gap-2">
            <span class={"badge badge-sm " <> if(fact.source == "user", do: "badge-primary", else: "badge-ghost")}>
              {fact.source}
            </span>
            <span class="flex-1">{fact.content}</span>
            <button
              class="btn btn-ghost btn-xs"
              phx-click="delete_fact"
              phx-value-id={fact.id}
              aria-label="delete fact"
            >
              ✕
            </button>
          </li>
          <li :if={@facts == []} class="text-sm opacity-50">No facts yet.</li>
        </ul>

        <form id="add-fact-form" phx-submit="add_fact" class="flex gap-2">
          <input
            type="text"
            name="content"
            value=""
            placeholder="Add something I should remember…"
            class="input input-bordered input-sm flex-1"
          />
          <button class="btn btn-sm" type="submit">Add</button>
        </form>
      </div>

      <div class="flex gap-2">
        <button class="btn btn-ghost btn-xs" phx-click="refresh_memory">Refresh</button>
        <button
          phx-click="forget_me"
          data-confirm={"Forget everything #{@assistant_name} knows about you?"}
          class="btn btn-error btn-sm"
        >
          Forget me
        </button>
      </div>
    </div>
    """
  end
end
