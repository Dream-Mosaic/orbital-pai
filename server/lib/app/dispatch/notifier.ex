defmodule App.Dispatch.Notifier do
  @moduledoc """
  Tells David when a dispatch job ends: an ntfy push to the phone AND a spoken line on the wall.

  A single GenServer subscribed to the GLOBAL `"dispatch"` topic only (`App.Dispatch` broadcasts
  every change on both `"dispatch:<uid>"` and `"dispatch"`; subscribing to both would double up).
  `notify/1` is also called directly by the watchdog. Dedupe is race-safe: `notified_at` is
  claimed with a conditional `update_all` (`where is_nil(notified_at)`), and only the caller that
  changed exactly one row sends anything, so a redelivered or concurrent message never notifies
  twice. An ntfy failure is logged and does not stop the wall line.
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

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_) do
    Phoenix.PubSub.subscribe(App.PubSub, "dispatch")
    {:ok, %{}}
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

    case Ntfy.publish(msg) do
      :ok ->
        :ok

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
  def click(job) do
    job.pr_url || issue_url(job) || run_url(job)
  end

  defp forge_url do
    case Application.get_env(:app, :forge) do
      %{url: url} when is_binary(url) and url != "" -> String.trim_trailing(url, "/")
      _ -> nil
    end
  end

  defp issue_url(%{issue: n} = job) when is_integer(n) do
    if base = forge_url(), do: "#{base}/#{job.repo}/issues/#{n}"
  end

  defp issue_url(_), do: nil

  defp run_url(%{run_number: n}) when is_integer(n) do
    if base = forge_url() do
      repo =
        case Application.get_env(:app, :forge) do
          %{dispatch_repo: r} when is_binary(r) and r != "" -> r
          _ -> "kalcode/claude-dispatch"
        end

      "#{base}/#{repo}/actions/runs/#{n}"
    end
  end

  defp run_url(_), do: nil

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
      |> String.split(~r/[.,;:!?\n]|\s[—–-]\s/, parts: 2)
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
