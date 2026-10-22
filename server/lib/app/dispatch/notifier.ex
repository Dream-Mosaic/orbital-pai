defmodule App.Dispatch.Notifier do
  @moduledoc """
  Tells David when a dispatch job ends: an ntfy push to the phone AND a spoken line on the wall.

  A single GenServer subscribed to the GLOBAL `"dispatch"` topic only (`App.Dispatch` broadcasts
  every change on both `"dispatch:<uid>"` and `"dispatch"`; subscribing to both would double up).
  `notify/1` is also called directly by the watchdog. Dedupe is race-safe: `notified_at` is
  claimed with a conditional `update_all` (`where is_nil(notified_at)`), and only the caller that
  changed exactly one row sends anything, so a redelivered or concurrent message never notifies
  twice. An ntfy failure, even a raise, is logged and does not stop the wall line.

  It starts on `:start_dispatch_notifier` alone, not on the forge: with the kill switch on, a
  job already running still reports back and must still be announced. On start it catches up
  on end states from the last 24 h that nobody announced (a deploy, a crash), through the same
  `notified_at` claim, so nothing is announced twice.
  """
  use GenServer
  require Logger

  alias App.Agenda
  alias App.Agenda.Item
  alias App.Dispatch
  alias App.Dispatch.{Job, Ntfy}

  @titles %{
    "pr" => "PR ready",
    "draft" => "Draft PR",
    "blocked" => "Claude is stuck",
    "failed" => "Claude job failed",
    "usage_limit" => "Claude hit your usage limit",
    "lost" => "Claude job went quiet"
  }
  @tags %{
    "pr" => "white_check_mark",
    "draft" => "memo",
    "blocked" => "warning",
    "failed" => "x",
    "usage_limit" => "hourglass_flowing_sand",
    "lost" => "ghost"
  }

  @catch_up_ms 24 * 3_600_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_) do
    Phoenix.PubSub.subscribe(App.PubSub, "dispatch")
    {:ok, %{}, {:continue, :catch_up}}
  end

  # Off init, so a slow ntfy can't hold up boot. Subscribed first: an end state that lands
  # meanwhile is in the mailbox, and the claim keeps it from being announced twice.
  @impl true
  def handle_continue(:catch_up, state) do
    since = DateTime.add(DateTime.utc_now(), -@catch_up_ms, :millisecond)

    try do
      n = Enum.count(Dispatch.unannounced_ends(since), &(notify(&1) == :notified))

      if n > 0,
        do:
          Logger.info(
            "[dispatch] announced #{n} job#{if n == 1, do: "", else: "s"} that ended while " <>
              "nobody was listening"
          )
    rescue
      e -> Logger.warning("[dispatch] notifier catch-up failed: #{inspect(e.__struct__)}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:dispatch_job, %Job{} = job}, state) do
    notify(job)
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  @doc "`:notified | :already_notified | :skipped` (not an end state)."
  def notify(%Job{status: status} = job) do
    cond do
      not Dispatch.end_state?(status) -> :skipped
      not Dispatch.claim_notice(job.id) -> :already_notified
      true -> deliver(job)
    end
  end

  defp deliver(job) do
    msg = %{
      title: title(job),
      message: detail(job) || title(job),
      click: click(job),
      tags: Map.get(@tags, job.status),
      priority: if(job.status in ~w(pr draft), do: "default", else: "high")
    }

    case push(msg) do
      :ok ->
        :ok

      {:error, {:raised, what}} ->
        Logger.warning("dispatch #{job.id}: ntfy push raised (#{what}); the wall line still goes")

      {:error, reason} ->
        Logger.warning("dispatch #{job.id}: ntfy not sent (#{inspect_reason(reason)})")
    end

    Agenda.deliver(job.user_id, %Item{
      kind: :heads_up,
      prompt: spoken(job),
      canned: true,
      deliver: :when_idle,
      expires_at: DateTime.add(DateTime.utc_now(), 2 * 3600, :second)
    })

    :notified
  end

  # The phone push must never cost the wall line. Only the exception's name is kept: a message
  # can carry the URL, and the URL carries the topic.
  defp push(msg) do
    Ntfy.publish(msg)
  rescue
    e -> {:error, {:raised, inspect(e.__struct__)}}
  catch
    :exit, _ -> {:error, {:raised, "exit"}}
  end

  defp inspect_reason({:http, s}), do: "HTTP #{s}"
  defp inspect_reason(a) when is_atom(a), do: Atom.to_string(a)
  defp inspect_reason(_), do: "transport error"

  @doc false
  def title(job), do: "#{Map.get(@titles, job.status, "Claude job update")}: #{label(job)}"

  defp label(job), do: "#{repo_name(job)} ##{job.issue}"
  defp repo_name(job), do: job.repo |> String.split("/") |> List.last()
  defp detail(job), do: blank_to_nil(job.summary) || blank_to_nil(job.reason)

  defp blank_to_nil(s) when is_binary(s),
    do: if(String.trim(s) == "", do: nil, else: String.trim(s))

  defp blank_to_nil(_), do: nil

  @doc false
  # Every link is on the forge's PUBLIC base (FORGE_PUBLIC_URL): the phone opens it, so it must
  # never be the LAN address the API uses.
  def click(job), do: job.pr_url || Dispatch.issue_url(job) || Dispatch.run_url(job)

  # One spoken sentence. Numbers are spelled out so Sonic says "thirty-one", not "three one".
  defp spoken(job) do
    what = "#{repo_name(job)} #{words(job.issue)}"

    lead =
      case job.status do
        "pr" -> "Claude's PR for #{what} is up"
        "draft" -> "Claude opened a draft PR for #{what}"
        "blocked" -> "Claude is stuck on #{what}"
        "failed" -> "Claude's job on #{what} failed"
        "usage_limit" -> "Claude hit your usage limit on #{what}"
        _ -> "Claude's job on #{what} went quiet"
      end

    case first_clause(detail(job)) do
      nil -> lead <> "."
      clause -> "#{lead} — #{clause}."
    end
  end

  defp first_clause(nil), do: nil

  defp first_clause(text) do
    clause =
      text
      |> speakable()
      # Sentence punctuation only before a space or the end, so "lib/app.ex" and "1.18" stay
      # whole; commas, newlines and a spaced dash always end it.
      |> String.split(~r/[.!?;:](?=\s|\z)|,|\n|\s[—–-]\s/u, parts: 2)
      |> hd()
      |> String.trim()
      |> String.slice(0, 120)

    if clause == "", do: nil, else: clause
  end

  # No symbols or URLs for TTS: links lose their target, markdown markers go.
  defp speakable(text) do
    text
    |> String.replace(~r/\[([^\]]*)\]\([^)]*\)/, "\\1")
    |> String.replace(~r{https?://[^\s,;)]+}, "")
    |> String.replace(~r/^\s*\#+\s*/m, "")
    |> String.replace(~r/[*`~]+/, "")
  end

  @ones ~w(zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen)
  @tens ~w(_ _ twenty thirty forty fifty sixty seventy eighty ninety)

  @doc false
  def words(n) when is_integer(n) and n >= 0 and n < 20, do: Enum.at(@ones, n)

  def words(n) when is_integer(n) and n < 100 do
    tens = Enum.at(@tens, div(n, 10))
    if rem(n, 10) == 0, do: tens, else: tens <> "-" <> words(rem(n, 10))
  end

  def words(n) when is_integer(n) and n < 1000 do
    h = words(div(n, 100)) <> " hundred"
    if rem(n, 100) == 0, do: h, else: h <> " " <> words(rem(n, 100))
  end

  def words(n), do: to_string(n)
end
