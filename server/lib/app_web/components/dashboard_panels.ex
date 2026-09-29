defmodule AppWeb.DashboardPanels do
  @moduledoc """
  Read-only function components for the admin dashboard (`AppWeb.ConversationLive`): the live
  status strip and thread rows, plus one panel per inspector tab.

  Nothing here writes. The only events are UI-local (`tab`, `show_book`), handled by the
  LiveView without touching data; every write belongs to the panel channels the app uses. The
  web's old duplicate write paths had drifted from those channels (spec
  2026-09-26-web-admin-dashboard-design), so a future write added here must call the same
  context function its channel does.

  The look borrows the phone's Meridian thread (`native/lib/meridian/thread.dart`): a spine
  with your turns to its left and Henry's answers to its right, in the same state colours
  (the `/* dashboard */` section of app.css). The rows position themselves on `--rail`, which
  the thread's container sets, so they only line up inside that container.
  """
  use AppWeb, :html

  alias App.Google.Connectors
  alias AppWeb.BookFormat
  alias AppWeb.ReminderFormat

  # The policy phases in the order a turn walks them (`App.Conversations.Policy`). The strip
  # lights a pip per step reached, so where a turn stands reads by position as well as name.
  @phases [:listening, :awaiting_reflex, :speaking_reflex, :streaming, :draining]

  # ---- the live conversation ----

  attr :status, :map, required: true
  attr :present, :list, default: []

  def status_strip(assigns) do
    assigns = assign(assigns, :pips, pips(assigns.status.phase))

    ~H"""
    <div
      id="status"
      data-phase={@status.phase}
      class="flex flex-wrap items-center gap-x-5 gap-y-2.5 text-sm"
    >
      <span id="status-session" class="inline-flex items-center gap-2 font-medium">
        <span class="inline-grid *:[grid-area:1/1]" aria-hidden="true">
          <span
            :if={@status.session == :live}
            class="status status-success animate-ping [animation-duration:2.4s] motion-reduce:animate-none"
          ></span>
          <span class={["status", session_class(@status.session)]}></span>
        </span>
        <span class={@status.session != :live && "text-base-content/60"}>
          {session_label(@status.session)}
        </span>
      </span>

      <div :if={@status.phase} id="status-phase" class="flex items-center gap-3">
        <span class="font-display text-lg font-semibold leading-none text-(--phase)">
          {phase_label(@status.phase)}
        </span>
        <span class="flex items-center gap-1" aria-hidden="true">
          <span :for={pip <- @pips} class={["h-1.5 w-4 rounded-full", pip]}></span>
        </span>
      </div>

      <span
        :if={is_boolean(@status.locked)}
        id="status-lock"
        title={lock_title(@status.locked)}
        class={[
          "inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 text-[13px] font-semibold ring-1 ring-inset",
          lock_class(@status.locked)
        ]}
      >
        <.icon name={lock_icon(@status.locked)} class="size-3.5" />
        {if @status.locked, do: "locked", else: "unlocked"}
      </span>

      <span
        :if={@status.bound_device}
        id="status-device"
        title={"Bound device #{@status.bound_device}"}
        class="inline-flex items-center gap-1.5 font-mono text-xs text-base-content/75"
      >
        <.icon name="hero-device-phone-mobile-micro" class="size-3.5 text-base-content/45" />
        {short_id(@status.bound_device)}
      </span>

      <span
        id="status-present"
        class="ms-auto inline-flex min-w-0 items-center gap-1.5 text-xs text-base-content/60"
      >
        <.icon name="hero-users-micro" class="size-3.5 shrink-0 text-base-content/40" />
        <span class="truncate">{present_line(@present)}</span>
      </span>
    </div>
    """
  end

  attr :row, :map, required: true
  attr :assistant_name, :string, default: "Henry"

  # Text bodies carry `phx-no-format` and keep the interpolation on the tag's own line:
  # they are `whitespace-pre-wrap` (answers carry real newlines), so any indentation the
  # formatter put inside the tag would render as a blank first line.
  def thread_row(%{row: %{kind: :you}} = assigns) do
    ~H"""
    <div
      class="relative mt-6 pl-[calc(var(--rail)+1.25rem)] @xl:w-[calc(var(--rail)-1.25rem)] @xl:pl-0 @xl:text-right"
      data-kind="you"
    >
      <.rail_node class="bg-you" />
      <p class="text-[11px] font-semibold leading-4 tracking-wide text-you">you</p>
      <p
        class="mt-1 whitespace-pre-wrap text-sm leading-relaxed text-you-body [overflow-wrap:anywhere]"
        phx-no-format
      >{@row.text}</p>
    </div>
    """
  end

  def thread_row(%{row: %{kind: :brain}} = assigns) do
    ~H"""
    <div class="relative mt-2.5 pl-[calc(var(--rail)+1.25rem)]" data-kind="brain">
      <.rail_node class="bg-henry" />
      <p class="text-[11px] font-semibold lowercase leading-4 tracking-wide text-henry">
        {@assistant_name}
      </p>
      <p
        class="mt-1 max-w-[72ch] whitespace-pre-wrap text-[15px] leading-relaxed text-brain-body [overflow-wrap:anywhere]"
        phx-no-format
      >{@row.text}</p>
    </div>
    """
  end

  # A tool call branches off the spine: it happens inside the answer, not as a turn of its own.
  def thread_row(%{row: %{kind: :tool}} = assigns) do
    ~H"""
    <div class="relative mt-1.5 pl-[calc(var(--rail)+1.25rem)]" data-kind="tool">
      <span
        aria-hidden="true"
        class="absolute top-1/2 left-[calc(var(--rail)+2px)] h-px w-4 bg-think/40"
      ></span>
      <span class="inline-flex max-w-full items-center gap-1.5 rounded-md border border-think/20 bg-think/[0.07] px-2 py-0.5 font-mono text-xs text-base-content/80">
        <.icon name="hero-wrench-screwdriver-micro" class="size-3.5 shrink-0 text-think" />
        <span class="[overflow-wrap:anywhere]">{@row.text}</span>
      </span>
    </div>
    """
  end

  def thread_row(%{row: %{kind: :metrics}} = assigns) do
    ~H"""
    <div
      class="relative mt-1.5 flex items-center gap-1.5 pl-[calc(var(--rail)+1.25rem)] font-mono text-[11px] tabular-nums text-base-content/55"
      data-kind="metrics"
    >
      <.icon name="hero-clock-micro" class="size-3 text-base-content/35" />
      {@row.text}
    </div>
    """
  end

  # A Voice Lock drop: an utterance was heard but rejected before it became a transcript.
  # Same style family as the tool/metrics asides (a dim, compact badge branching off the
  # spine) — NOT the generic clause below, which renders a full you/brain-shaped bubble with
  # its own label line.
  def thread_row(%{row: %{kind: :gate}} = assigns) do
    ~H"""
    <div class="relative mt-1.5 pl-[calc(var(--rail)+1.25rem)]" data-kind="gate">
      <span
        aria-hidden="true"
        class="absolute top-1/2 left-[calc(var(--rail)+2px)] h-px w-4 bg-base-content/15"
      ></span>
      <span class="inline-flex max-w-full items-center gap-1.5 rounded-md border border-base-content/15 bg-base-content/[0.04] px-2 py-0.5 font-mono text-xs text-base-content/50">
        <.icon name="hero-shield-exclamation-micro" class="size-3.5 shrink-0 text-base-content/35" />
        <span class="[overflow-wrap:anywhere]">{@row.text}</span>
      </span>
    </div>
    """
  end

  # Spoken asides and agenda leads: the reflex filler, and a reminder, briefing or follow-up
  # opening a turn nobody asked for.
  def thread_row(assigns) do
    ~H"""
    <div
      class={["relative pl-[calc(var(--rail)+1.25rem)]", aside_margin(@row.kind)]}
      data-kind={@row.kind}
    >
      <.rail_node class={aside_node(@row.kind)} />
      <p class={["text-[11px] font-semibold leading-4 tracking-wide", aside_label(@row.kind)]}>
        {@row.kind}
      </p>
      <p
        class={[
          "mt-1 max-w-[72ch] whitespace-pre-wrap leading-relaxed [overflow-wrap:anywhere]",
          aside_body(@row.kind)
        ]}
        phx-no-format
      >{@row.text}</p>
    </div>
    """
  end

  attr :class, :any, default: nil

  # A row's dot on the spine, centred on the spine and on the row's label line.
  defp rail_node(assigns) do
    ~H"""
    <span
      aria-hidden="true"
      class={[
        "absolute top-[4.5px] left-[calc(var(--rail)-2.75px)] size-[7px] rounded-full",
        @class
      ]}
    ></span>
    """
  end

  # ---- inspector panels ----

  attr :title, :string, required: true
  attr :count, :integer, default: nil

  defp heading(assigns) do
    ~H"""
    <h3 class="flex items-baseline gap-2 font-display text-[13px] font-semibold text-base-content/90">
      {@title}
      <span :if={@count} class="font-sans text-xs font-normal tabular-nums text-base-content/45">
        {@count}
      </span>
    </h3>
    """
  end

  attr :due, :list, required: true
  attr :upcoming, :list, required: true

  def reminders_panel(assigns) do
    ~H"""
    <div id="panel-reminders" class="space-y-6 text-sm">
      <section :if={@due != []} class="space-y-1.5">
        <.heading title="Needs attention" count={length(@due)} />
        <ul class="divide-y divide-base-content/[0.06]">
          <li :for={r <- @due} class="flex items-start gap-3 py-2">
            <.icon
              name="hero-exclamation-triangle-micro"
              class="mt-0.5 size-4 shrink-0 text-warning"
            />
            <.reminder_body r={r} />
          </li>
        </ul>
      </section>
      <section class="space-y-1.5">
        <.heading title="Upcoming" count={length(@upcoming)} />
        <ul class="divide-y divide-base-content/[0.06]">
          <li :for={r <- @upcoming} class="flex items-start gap-3 py-2">
            <.icon name="hero-bell-micro" class="mt-0.5 size-4 shrink-0 text-base-content/35" />
            <.reminder_body r={r} />
          </li>
          <li :if={@upcoming == []} class="py-2 text-base-content/55">
            Nothing scheduled. Reminders set by voice or in the app land here.
          </li>
        </ul>
      </section>
    </div>
    """
  end

  attr :r, :map, required: true

  defp reminder_body(assigns) do
    ~H"""
    <div class="min-w-0 flex-1 space-y-1">
      <p class="leading-snug">{@r.body}</p>
      <div
        :if={@r.kind == "followup" or @r.household or @r.recurrence}
        class="flex flex-wrap gap-1"
      >
        <span :if={@r.kind == "followup"} class="badge badge-xs badge-soft badge-secondary">
          follow-up
        </span>
        <span :if={@r.household} class="badge badge-xs badge-soft badge-accent">shared</span>
        <span :if={@r.recurrence} class="badge badge-xs badge-soft badge-info">
          {ReminderFormat.fmt_recurrence(@r.recurrence, @r.due_at)}
        </span>
      </div>
    </div>
    <span class="shrink-0 pt-px font-mono text-xs tabular-nums text-base-content/55">
      {ReminderFormat.fmt_due(@r.due_at)}
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
    <div id="panel-books" class="space-y-5 text-sm">
      <div class="flex flex-wrap gap-1">
        <button
          :for={b <- @books}
          type="button"
          phx-click="show_book"
          phx-value-key={b.key}
          aria-pressed={to_string(b.key == @current_book.key)}
          class={[
            "btn btn-xs",
            (b.key == @current_book.key && "btn-soft btn-primary") || "btn-ghost"
          ]}
        >
          <.icon name={b.icon} class="size-3.5" /> {b.label}
        </button>
      </div>

      <section :if={@current_book.kind == :list and @current_list} class="space-y-1.5">
        <div class="flex items-center gap-2">
          <.heading title={@current_list.name} count={length(@current_list.items)} />
          <span :if={@current_list.household} class="badge badge-xs badge-soft badge-accent">
            shared
          </span>
        </div>
        <ul class="divide-y divide-base-content/[0.06]">
          <li
            :for={item <- BookFormat.sorted_items(@current_list)}
            class="flex items-center gap-2.5 py-1.5"
          >
            <.icon :if={item.checked_at} name="hero-check-circle-mini" class="size-4 text-henry/70" />
            <span
              :if={!item.checked_at}
              aria-hidden="true"
              class="mx-0.5 size-3 rounded-[3px] border border-base-content/35"
            ></span>
            <span class={[item.checked_at && "text-base-content/45 line-through"]}>
              {item.text}
            </span>
          </li>
          <li :if={@current_list.items == []} class="py-1.5 text-base-content/55">
            Nothing on it.
          </li>
        </ul>
      </section>
      <p :if={@current_book.kind == :list and !@current_list} class="text-base-content/55">
        That list is gone.
      </p>

      <div :if={@current_book.kind == :garden} class="space-y-5">
        <section class="space-y-1.5">
          <.heading title="Growing" count={length(@garden.active)} />
          <ul class="divide-y divide-base-content/[0.06]">
            <li :for={plant <- @garden.active} class="space-y-1 py-2">
              <div class="flex items-center gap-2">
                <span class="flex-1 font-medium">{plant.name}</span>
                <span :if={plant.household} class="badge badge-xs badge-soft badge-accent">
                  shared
                </span>
              </div>
              <p :if={BookFormat.plant_meta(plant) != ""} class="text-xs text-base-content/55">
                {BookFormat.plant_meta(plant)}
              </p>
              <ul :if={plant.notes != []} class="space-y-1 pt-0.5">
                <li :for={note <- plant.notes} class="flex gap-3 text-[13px]">
                  <span class="flex-1 text-base-content/80">{note.body}</span>
                  <span class="shrink-0 font-mono text-xs tabular-nums text-base-content/50">
                    {BookFormat.fmt_noted(note)}
                  </span>
                </li>
              </ul>
            </li>
          </ul>
          <p :if={@garden.active == []} class="text-base-content/55">Nothing growing.</p>
        </section>
        <section
          :for={{season, plants} <- BookFormat.seasons_desc(@garden.archived_by_season)}
          class="space-y-1"
        >
          <.heading title={season} count={length(plants)} />
          <p class="text-base-content/70">{Enum.map_join(plants, ", ", & &1.name)}</p>
        </section>
      </div>
    </div>
    """
  end

  attr :facts, :list, required: true
  attr :summary, :string, default: nil

  def memory_panel(assigns) do
    ~H"""
    <div id="panel-memory" class="space-y-6 text-sm">
      <section class="space-y-2">
        <.heading title="Rolling summary" />
        <p
          :if={@summary not in [nil, ""]}
          class="whitespace-pre-wrap leading-relaxed text-base-content/85"
          phx-no-format
        >{@summary}</p>
        <p :if={@summary in [nil, ""]} class="text-base-content/55">
          Nothing yet. The summary is written after a few turns.
        </p>
      </section>
      <section class="space-y-1.5">
        <.heading title="Profile facts" count={length(@facts)} />
        <ul class="divide-y divide-base-content/[0.06]">
          <li :for={fact <- @facts} class="flex items-start gap-3 py-2">
            <span class="flex-1 leading-snug">{fact.content}</span>
            <span class={[
              "badge badge-xs mt-0.5 shrink-0",
              (fact.source == "user" && "badge-soft badge-primary") ||
                "badge-ghost text-base-content/60"
            ]}>
              {fact.source}
            </span>
          </li>
          <li :if={@facts == []} class="py-2 text-base-content/55">No facts yet.</li>
        </ul>
      </section>
    </div>
    """
  end

  attr :google_accounts, :list, required: true

  def connectors_panel(assigns) do
    assigns = assign(assigns, :rows, connection_rows(assigns.google_accounts))

    ~H"""
    <ul id="panel-connectors" class="divide-y divide-base-content/[0.06] text-sm">
      <li :for={{conn, a} <- @rows} class="flex items-center gap-3 py-2.5">
        <div class="min-w-0 flex-1">
          <p class="font-medium">{Connectors.label(conn)}</p>
          <p class="truncate text-xs text-base-content/55" title={a.email}>{a.email}</p>
        </div>
        <span
          :if={a.is_default and multi?(@google_accounts, conn)}
          class="badge badge-xs badge-soft badge-primary"
        >
          default
        </span>
        <span class="badge badge-xs badge-ghost">{Connectors.access(a, conn)}</span>
      </li>
      <li :if={@rows == []} class="py-2.5 text-base-content/55">
        No connections. Connect accounts from the app.
      </li>
    </ul>
    """
  end

  attr :user, :map, required: true
  attr :app_version, :string, required: true

  def settings_panel(assigns) do
    ~H"""
    <div id="panel-settings" class="space-y-6 text-sm">
      <section class="space-y-1.5">
        <.heading title="Account" />
        <p class="font-medium">{@user.name}</p>
        <p class="text-base-content/60">{@user.email}</p>
      </section>
      <section class="space-y-1.5">
        <.heading title="Voice defaults" />
        <dl class="divide-y divide-base-content/[0.06]">
          <.setting label="Allow barge-in" value={on_off(@user.default_abi)} />
          <.setting label="Push-to-talk" value={on_off(@user.default_ptt)} />
          <.setting label="Wake word" value={on_off(@user.voice_activation)} />
          <.setting label="Morning briefing" value={@user.briefing_time || "off"} />
          <.setting label="Lockdown timeout" value={"#{@user.relock_seconds}s"} />
        </dl>
      </section>
      <section class="space-y-1.5">
        <.heading title="About" />
        <p class="font-mono text-xs text-base-content/60">P.A.I v{@app_version}</p>
      </section>
      <p class="text-xs text-base-content/50">Change these in the app.</p>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true

  defp setting(assigns) do
    ~H"""
    <div class="flex items-baseline justify-between gap-4 py-1.5">
      <dt class="text-base-content/70">{@label}</dt>
      <dd class="font-medium tabular-nums">{@value}</dd>
    </div>
    """
  end

  attr :vl, :map, required: true

  def voice_lock_panel(assigns) do
    ~H"""
    <div id="panel-voice-lock" class="space-y-6 text-sm">
      <p :if={!@vl.verifier_ready} role="alert" class="alert alert-warning alert-soft">
        Speaker model unavailable — Voice Lock is failing open (everything passes).
      </p>
      <dl class="divide-y divide-base-content/[0.06]">
        <.setting label="Mode" value={to_string(@vl.mode)} />
        <.setting label="Enrolled prompts" value={"#{length(@vl.enrolled_slots)} of 3"} />
      </dl>
      <section class="space-y-1.5">
        <.heading title="Recently filtered" count={length(@vl.drops)} />
        <ul class="divide-y divide-base-content/[0.06] text-xs">
          <li :for={e <- @vl.drops} class="flex items-center gap-2 py-1.5">
            <span class="badge badge-xs badge-ghost">{e.decision}</span>
            <span class="flex-1 truncate text-base-content/80" title={e.transcript}>
              {e.transcript}
            </span>
            <span class="font-mono tabular-nums text-base-content/55">
              {e.score && Float.round(e.score, 2)}
            </span>
          </li>
          <li :if={@vl.drops == []} class="py-1.5 text-base-content/55">
            Nothing filtered yet.
          </li>
        </ul>
      </section>
    </div>
    """
  end

  # ---- helpers ----

  defp session_label(:live), do: "live"
  defp session_label(_), do: "no session"

  defp session_class(:live), do: "status-success"
  defp session_class(_), do: "status-neutral"

  defp phase_label(phase), do: phase |> to_string() |> String.replace("_", " ")

  # One class per pip: the steps already walked this turn, dimmed; the current one, full; the
  # rest unlit. An unknown phase lights nothing rather than guessing a position.
  defp pips(phase) do
    at = Enum.find_index(@phases, &(&1 == phase))

    for i <- 0..(length(@phases) - 1) do
      cond do
        is_nil(at) or i > at -> "bg-base-content/10"
        i == at -> "bg-(--phase)"
        true -> "bg-(--phase)/35"
      end
    end
  end

  # Locked is the resting state (asleep until someone says the wake word); unlocked means
  # every utterance reaches the assistant, which is the one worth noticing from across a room.
  defp lock_class(true), do: "bg-base-content/[0.06] text-base-content/85 ring-base-content/15"
  defp lock_class(false), do: "bg-you/10 text-you ring-you/35"

  defp lock_icon(true), do: "hero-lock-closed-micro"
  defp lock_icon(false), do: "hero-lock-open-micro"

  defp lock_title(true), do: "Wake lock on: waiting for the wake word"
  defp lock_title(false), do: "Awake: every utterance reaches the assistant"

  defp aside_margin(kind) when kind in [:reminder, :briefing, :followup], do: "mt-6"
  defp aside_margin(_kind), do: "mt-2.5"

  defp aside_node(:reminder), do: "bg-you"
  defp aside_node(:briefing), do: "bg-drain"
  defp aside_node(:followup), do: "bg-followup"
  defp aside_node(_kind), do: "border border-base-content/40 bg-base-200"

  defp aside_label(:reminder), do: "text-you"
  defp aside_label(:briefing), do: "text-drain"
  defp aside_label(:followup), do: "text-followup"
  defp aside_label(_kind), do: "text-base-content/45"

  defp aside_body(kind) when kind in [:reminder, :briefing, :followup],
    do: "text-[15px] text-brain-body"

  defp aside_body(_kind), do: "text-sm italic text-base-content/60"

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
