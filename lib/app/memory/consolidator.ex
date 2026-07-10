defmodule App.Memory.Consolidator do
  @moduledoc """
  Nightly memory consolidation (03:00-05:00 local, once per user per day; the digest row is
  the claim). Per user: (1) digest yesterday's turns, (2) merge/dedupe auto facts,
  (3) rebuild the rolling summary from facts + recent digests — NOT from the old summary, so
  self-feeding drift dies each night. ~3 memory-tier model calls per user.
  Spec: docs/superpowers/specs/2026-07-03-memory-pack-design.md
  """
  use GenServer
  require Logger

  alias App.Memory

  @interval_ms 60 * 60 * 1000
  @summary_word_cap 160

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_) do
    schedule()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    local = DateTime.now!(App.Config.default().timezone)

    if window?(DateTime.to_time(local)) do
      for user <- App.Users.list() do
        run_user(user.id, DateTime.to_date(local))
      end
    end

    schedule()
    {:noreply, state}
  end

  @doc "Inside the nightly window?"
  def window?(%Time{} = t),
    do: Time.compare(t, ~T[03:00:00]) != :lt and Time.compare(t, ~T[05:00:00]) != :gt

  @doc "Consolidate one user for `today` (idempotent — the digest row claims the day)."
  def run_user(user_id, today) do
    yesterday = Date.add(today, -1)

    if digest_needed?(user_id, yesterday) do
      with :ok <- digest_day(user_id, yesterday),
           :ok <- merge_facts(user_id),
           :ok <- rebuild_summary(user_id) do
        Logger.info("[consolidator] user #{user_id}: consolidated #{yesterday}")
        :ok
      end
    else
      :ok
    end
  rescue
    e ->
      Logger.error("[consolidator] user #{user_id} failed: #{inspect(e)}")
      :ok
  end

  @doc false
  def digest_needed?(user_id, date),
    do: not Enum.any?(Memory.digests_for(user_id, 1), &(&1.date == date))

  defp digest_day(user_id, date) do
    case Memory.turns_on(user_id, date) do
      [] ->
        # claim the day anyway so we don't rescan forever
        Memory.put_digest(user_id, date, "(quiet day — no conversations)")
        :ok

      turns ->
        convo =
          Enum.map_join(turns, "\n", fn t ->
            "User: #{t.user_text}\nAssistant: #{t.brain_text}"
          end)

        prompt =
          "Write a single ~100-word digest of this day's conversations between a user and " <>
            "their voice assistant. Only what actually happened/was said — no invention, no " <>
            "advice. Plain prose.\n\n#{convo}"

        case model().generate(prompt, %{},
               tier: :memory,
               config: App.Config.default(),
               thinking: "low"
             ) do
          {:ok, digest} when is_binary(digest) and digest != "" ->
            Memory.put_digest(user_id, date, String.trim(digest))
            :ok

          _ ->
            :ok
        end
    end
  end

  defp merge_facts(user_id) do
    facts = Memory.list_facts(user_id)
    auto = for f <- facts, f.source == "auto", do: f.content

    if length(auto) > 1 do
      prompt =
        "Merge and deduplicate this list of facts about a user. Combine semantic duplicates " <>
          "into one best phrasing; keep each fact atomic, <= 12 words, one per line; drop " <>
          "nothing that is genuinely distinct. Output only the lines.\n\n" <>
          Enum.join(auto, "\n")

      case model().generate(prompt, %{},
             tier: :memory,
             config: App.Config.default(),
             thinking: "low"
           ) do
        {:ok, merged} when is_binary(merged) ->
          lines =
            merged
            |> String.split("\n", trim: true)
            |> Enum.map(&String.replace(&1, ~r/^[-*\d.\s]+/, ""))
            |> Enum.reject(&(&1 == "" or String.length(&1) > 120))
            |> Enum.take(30)

          if lines != [], do: Memory.replace_auto_facts(user_id, lines)
          :ok

        _ ->
          :ok
      end
    else
      :ok
    end
  end

  defp rebuild_summary(user_id) do
    facts = Memory.list_facts(user_id) |> Enum.map_join("\n", & &1.content)
    digests = Memory.digests_for(user_id, 3) |> Enum.map_join("\n", &"#{&1.date}: #{&1.content}")

    prompt =
      "Rebuild the memory of a user for a voice assistant from these sources. <= 120 words, " <>
        "plain text, FACTUAL — only what the sources support, written about the user.\n\n" <>
        "Known facts:\n#{facts}\n\nRecent days:\n#{digests}"

    case model().generate(prompt, %{},
           tier: :memory,
           config: App.Config.default(),
           thinking: "low"
         ) do
      {:ok, summary} when is_binary(summary) and summary != "" ->
        Memory.put_summary(user_id, cap(summary))
        :ok

      _ ->
        :ok
    end
  end

  defp cap(text) do
    words = String.split(text)

    if length(words) > @summary_word_cap,
      do: Enum.join(Enum.take(words, @summary_word_cap), " "),
      else: String.trim(text)
  end

  defp schedule, do: Process.send_after(self(), :tick, @interval_ms)
  defp model, do: Application.fetch_env!(:app, :text_model)
end
