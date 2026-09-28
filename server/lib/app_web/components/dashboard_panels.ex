defmodule AppWeb.DashboardPanels do
  @moduledoc """
  Read-only function components for the admin dashboard (`AppWeb.ConversationLive`): the live
  status strip and thread rows, plus one panel per inspector tab.

  Nothing here writes. The only events are UI-local (`tab`, `show_book`), handled by the
  LiveView without touching data; every write belongs to the panel channels the app uses. The
  web's old duplicate write paths had drifted from those channels (spec
  2026-09-26-web-admin-dashboard-design), so a future write added here must call the same
  context function its channel does.
  """
  use AppWeb, :html

  alias App.Google.Connectors
  alias AppWeb.BookFormat
  alias AppWeb.ReminderFormat

  # ---- the live conversation ----

  attr :status, :map, required: true
  attr :present, :list, default: []

  def status_strip(assigns) do
    ~H"""
    <div id="status" class="flex flex-wrap items-center gap-2 text-sm">
      <span id="status-session" class={["badge badge-sm", session_class(@status.session)]}>
        {session_label(@status.session)}
      </span>
      <span :if={@status.phase} id="status-phase" class="badge badge-sm badge-outline">
        {phase_label(@status.phase)}
      </span>
      <span :if={is_boolean(@status.locked)} id="status-lock" class="badge badge-sm badge-outline">
        {if @status.locked, do: "locked", else: "unlocked"}
      </span>
      <span
        :if={@status.bound_device}
        id="status-device"
        class="badge badge-sm badge-outline font-mono"
        title={@status.bound_device}
      >
        {short_id(@status.bound_device)}
      </span>
      <span id="status-present" class="ml-auto text-xs opacity-60">{present_line(@present)}</span>
    </div>
    """
  end

  attr :row, :map, required: true
  attr :assistant_name, :string, default: "Henry"

  def thread_row(assigns) do
    ~H"""
    <div :if={@row.kind == :you} class="chat chat-end" data-kind="you">
      <div class="chat-bubble chat-bubble-warning whitespace-pre-wrap">{@row.text}</div>
    </div>
    <div :if={@row.kind == :brain} class="chat chat-start" data-kind="brain">
      <div class="chat-header text-xs opacity-60">{@assistant_name}</div>
      <div class="chat-bubble whitespace-pre-wrap">{@row.text}</div>
    </div>
    <div
      :if={@row.kind == :tool}
      class="flex items-center gap-1 pl-2 text-xs italic opacity-60"
      data-kind="tool"
    >
      <.icon name="hero-wrench-screwdriver" class="size-3" /> {@row.text}
    </div>
    <div
      :if={@row.kind == :metrics}
      class="text-right font-mono text-xs opacity-50"
      data-kind="metrics"
    >
      {@row.text}
    </div>
    <div
      :if={@row.kind not in [:you, :brain, :tool, :metrics]}
      class="chat chat-start"
      data-kind={@row.kind}
    >
      <div class="chat-header text-xs opacity-60">{@row.kind}</div>
      <div class="chat-bubble chat-bubble-neutral whitespace-pre-wrap opacity-80">{@row.text}</div>
    </div>
    """
  end

  # ---- inspector panels ----

  attr :due, :list, required: true
  attr :upcoming, :list, required: true

  def reminders_panel(assigns) do
    ~H"""
    <div id="panel-reminders" class="space-y-4 text-sm">
      <div :if={@due != []} class="space-y-1">
        <h3 class="text-xs uppercase opacity-60">Needs attention</h3>
        <ul class="space-y-1">
          <li :for={r <- @due} class="flex items-center gap-2">
            <span class="badge badge-sm badge-warning">due</span>
            <.reminder_badges r={r} />
            <span class="flex-1">{r.body}</span>
            <span class="font-mono text-xs opacity-60">{ReminderFormat.fmt_due(r.due_at)}</span>
          </li>
        </ul>
      </div>
      <div class="space-y-1">
        <h3 class="text-xs uppercase opacity-60">Upcoming</h3>
        <ul class="space-y-1">
          <li :for={r <- @upcoming} class="flex items-center gap-2">
            <.reminder_badges r={r} />
            <span class="flex-1">{r.body}</span>
            <span class="font-mono text-xs opacity-60">{ReminderFormat.fmt_due(r.due_at)}</span>
          </li>
          <li :if={@upcoming == []} class="opacity-50">Nothing scheduled.</li>
        </ul>
      </div>
    </div>
    """
  end

  attr :r, :map, required: true

  defp reminder_badges(assigns) do
    ~H"""
    <span :if={@r.kind == "followup"} class="badge badge-sm badge-ghost">follow-up</span>
    <span :if={@r.household} class="badge badge-sm badge-accent">shared</span>
    <span :if={@r.recurrence} class="badge badge-sm badge-info">
      {ReminderFormat.fmt_recurrence(@r.recurrence, @r.due_at)}
    </span>
    """
  end

  attr :books, :list, required: true
  attr :current_book, :map, required: true
  attr :lists, :list, required: true
  attr :garden, :map, required: true

  def books_panel(assigns) do
    assigns = assign(assigns, :current_list, current_list(assigns.lists, assigns.current_book))

    ~H"""
    <div id="panel-books" class="space-y-4 text-sm">
      <div class="flex flex-wrap gap-1">
        <button
          :for={b <- @books}
          type="button"
          phx-click="show_book"
          phx-value-key={b.key}
          class={["btn btn-xs", (b.key == @current_book.key && "btn-primary") || "btn-ghost"]}
        >
          <.icon name={b.icon} class="size-3" /> {b.label}
        </button>
      </div>

      <div :if={@current_book.kind == :list and @current_list} class="space-y-1">
        <div class="flex items-center gap-2">
          <span class="font-semibold">{@current_list.name}</span>
          <span :if={@current_list.household} class="badge badge-sm badge-accent">shared</span>
        </div>
        <ul class="space-y-1">
          <li :for={item <- BookFormat.sorted_items(@current_list)} class="flex items-center gap-2">
            <.icon
              name={(item.checked_at && "hero-check-circle") || "hero-stop"}
              class="size-4 opacity-60"
            />
            <span class={[item.checked_at && "line-through opacity-50"]}>{item.text}</span>
          </li>
          <li :if={@current_list.items == []} class="opacity-50">Nothing on it.</li>
        </ul>
      </div>
      <p :if={@current_book.kind == :list and !@current_list} class="opacity-50">
        That list is gone.
      </p>

      <div :if={@current_book.kind == :garden} class="space-y-3">
        <div :for={plant <- @garden.active} class="rounded-box border border-base-300 p-3">
          <div class="flex items-center gap-2">
            <span class="flex-1 font-semibold">{plant.name}</span>
            <span :if={plant.household} class="badge badge-sm badge-accent">shared</span>
          </div>
          <p :if={BookFormat.plant_meta(plant) != ""} class="text-xs opacity-60">
            {BookFormat.plant_meta(plant)}
          </p>
          <ul :if={plant.notes != []} class="mt-1 space-y-1">
            <li :for={note <- plant.notes} class="flex gap-2">
              <span class="flex-1">{note.body}</span>
              <span class="font-mono text-xs opacity-60">{BookFormat.fmt_noted(note)}</span>
            </li>
          </ul>
        </div>
        <p :if={@garden.active == []} class="opacity-50">Nothing growing.</p>
        <div :for={{season, plants} <- BookFormat.seasons_desc(@garden.archived_by_season)}>
          <h3 class="text-xs uppercase opacity-60">{season}</h3>
          <p class="opacity-70">{Enum.map_join(plants, ", ", & &1.name)}</p>
        </div>
      </div>
    </div>
    """
  end

  attr :facts, :list, required: true
  attr :summary, :string, default: nil

  def memory_panel(assigns) do
    ~H"""
    <div id="panel-memory" class="space-y-4 text-sm">
      <div class="space-y-1">
        <h3 class="text-xs uppercase opacity-60">Rolling summary</h3>
        <p :if={@summary not in [nil, ""]} class="whitespace-pre-wrap">{@summary}</p>
        <p :if={@summary in [nil, ""]} class="opacity-50">Nothing yet.</p>
      </div>
      <div class="space-y-1">
        <h3 class="text-xs uppercase opacity-60">Profile facts ({length(@facts)})</h3>
        <ul class="space-y-1">
          <li :for={fact <- @facts} class="flex items-start gap-2">
            <span class={[
              "badge badge-sm",
              (fact.source == "user" && "badge-primary") || "badge-ghost"
            ]}>
              {fact.source}
            </span>
            <span class="flex-1">{fact.content}</span>
          </li>
          <li :if={@facts == []} class="opacity-50">No facts yet.</li>
        </ul>
      </div>
    </div>
    """
  end

  attr :google_accounts, :list, required: true

  def connectors_panel(assigns) do
    assigns = assign(assigns, :rows, connection_rows(assigns.google_accounts))

    ~H"""
    <ul id="panel-connectors" class="space-y-2 text-sm">
      <li :for={{conn, a} <- @rows} class="flex items-center gap-2">
        <span class="flex-1">
          {Connectors.label(conn)} <span class="opacity-60">({a.email})</span>
        </span>
        <span
          :if={a.is_default and multi?(@google_accounts, conn)}
          class="badge badge-sm badge-primary"
        >
          default
        </span>
        <span class="badge badge-sm badge-ghost">{Connectors.access(a, conn)}</span>
      </li>
      <li :if={@rows == []} class="opacity-50">No connections. Connect accounts from the app.</li>
    </ul>
    """
  end

  attr :user, :map, required: true
  attr :app_version, :string, required: true

  def settings_panel(assigns) do
    ~H"""
    <div id="panel-settings" class="space-y-4 text-sm">
      <section class="space-y-1">
        <h3 class="text-xs uppercase opacity-60">Account</h3>
        <p>{@user.name}</p>
        <p class="opacity-60">{@user.email}</p>
      </section>
      <section class="space-y-1">
        <h3 class="text-xs uppercase opacity-60">Voice defaults</h3>
        <dl class="grid grid-cols-[1fr_auto] gap-x-4 gap-y-1">
          <dt>Allow barge-in</dt>
          <dd>{on_off(@user.default_abi)}</dd>
          <dt>Push-to-talk</dt>
          <dd>{on_off(@user.default_ptt)}</dd>
          <dt>Wake word</dt>
          <dd>{on_off(@user.voice_activation)}</dd>
          <dt>Morning briefing</dt>
          <dd>{@user.briefing_time || "off"}</dd>
          <dt>Lockdown timeout</dt>
          <dd>{@user.relock_seconds}s</dd>
        </dl>
      </section>
      <section class="space-y-1">
        <h3 class="text-xs uppercase opacity-60">About</h3>
        <p class="opacity-60">P.A.I v{@app_version}</p>
      </section>
      <p class="text-xs opacity-50">Change these in the app.</p>
    </div>
    """
  end

  attr :vl, :map, required: true

  def voice_lock_panel(assigns) do
    ~H"""
    <div id="panel-voice-lock" class="space-y-4 text-sm">
      <p :if={!@vl.verifier_ready} class="alert alert-warning">
        Speaker model unavailable — Voice Lock is failing open (everything passes).
      </p>
      <dl class="grid grid-cols-[1fr_auto] gap-x-4 gap-y-1">
        <dt>Mode</dt>
        <dd class="font-semibold">{@vl.mode}</dd>
        <dt>Enrolled prompts</dt>
        <dd>{length(@vl.enrolled_slots)} of 3</dd>
      </dl>
      <div class="space-y-1">
        <h3 class="text-xs uppercase opacity-60">Recently filtered</h3>
        <ul class="space-y-1 text-xs">
          <li :for={e <- @vl.drops} class="flex items-center gap-2">
            <span class="badge badge-xs badge-ghost">{e.decision}</span>
            <span class="flex-1 truncate opacity-80">{e.transcript}</span>
            <span class="font-mono opacity-60">{e.score && Float.round(e.score, 2)}</span>
          </li>
          <li :if={@vl.drops == []} class="opacity-50">Nothing filtered yet.</li>
        </ul>
      </div>
    </div>
    """
  end

  # ---- helpers ----

  defp session_label(:live), do: "live"
  defp session_label(_), do: "no session"

  defp session_class(:live), do: "badge-success"
  defp session_class(_), do: "badge-ghost"

  defp phase_label(phase), do: phase |> to_string() |> String.replace("_", " ")

  defp short_id(id), do: String.slice(id, 0, 8)

  defp present_line([]), do: "no one connected"

  defp present_line(present),
    do: Enum.map_join(present, ", ", &"#{&1.name} (#{if &1.kiosk, do: "wall", else: "app"})")

  defp on_off(true), do: "on"
  defp on_off(_), do: "off"

  defp current_list(lists, %{kind: :list, id: id}), do: Enum.find(lists, &(&1.id == id))
  defp current_list(_lists, _book), do: nil

  defp connection_rows(accounts) do
    for(a <- accounts, conn <- Connectors.granted(a), do: {conn, a})
    |> Enum.sort_by(fn {conn, a} -> {Connectors.label(conn), a.email} end)
  end

  defp multi?(accounts, connector),
    do: Enum.count(accounts, &(Connectors.access(&1, connector) != :none)) >= 2
end
