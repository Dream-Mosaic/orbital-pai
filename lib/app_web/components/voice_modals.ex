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
  defp modal_title(:connectors), do: "Connectors"
  defp modal_title(:settings), do: "Settings"
  defp modal_title(_), do: ""

  @doc "Reminders modal contents: due (needs attention) list + upcoming list, each with dismiss buttons."
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
            <span class="flex-1">{r.body}</span>
            <span class="text-xs opacity-60 font-mono">{fmt_due(r.due_at)}</span>
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
            <span class="flex-1">{r.body}</span>
            <span class="text-xs opacity-60 font-mono">{fmt_due(r.due_at)}</span>
            <button
              class="btn btn-ghost btn-xs"
              phx-click="dismiss_reminder"
              phx-value-id={r.id}
              aria-label="delete reminder"
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
