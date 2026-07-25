defmodule App.Sources.Gmail do
  @moduledoc """
  Gmail as a semantic source. `list_refs` lists message ids matching the tunable index query
  (`App.Config` `gmail_index_query`) — email is immutable, so `content_hash == external_id` and the
  diff is pure id membership. `to_point` fetches the full body for a *new* id and builds the
  embeddable text + payload. Reconcile is `:age_out` (a DB-only sweep drops rows older than
  `gmail_index_max_age_days`; an aged-out message simply stops matching the query).
  """
  @behaviour App.Sources

  alias App.Google.Gmail

  @body_cap 24_000
  @snippet_cap 240

  @impl true
  def source_key, do: "email"

  @impl true
  def connector, do: :gmail

  @impl true
  def reconcile_mode, do: :age_out

  @impl true
  def list_refs(account) do
    cfg = App.Config.default()

    with {:ok, ids} <-
           Gmail.list_message_ids(account,
             q: cfg.gmail_index_query,
             max_results: cfg.gmail_index_max_results
           ) do
      {:ok, Enum.map(ids, &%{external_id: &1, content_hash: &1, raw: &1})}
    end
  end

  @impl true
  def to_point(account, %{external_id: id}) do
    with {:ok, msg} <- Gmail.get_message(account, id) do
      at = at_datetime(msg.internal_date)
      body = msg.body || ""

      {:ok,
       %{
         embed_text:
           "Subject: #{msg.subject}\nFrom: #{msg.from}\nDate: #{msg.date}\n\n#{String.slice(body, 0, @body_cap)}",
         at: at,
         payload: %{
           user_id: account.user_id,
           source: "email",
           external_id: id,
           account_id: account.id,
           account: account.label,
           at: at_iso(at, msg.date),
           link: "https://mail.google.com/mail/u/0/#all/#{id}",
           subject: msg.subject,
           from: msg.from,
           snippet: String.slice(body, 0, @snippet_cap)
         }
       }}
    end
  end

  defp at_datetime(ms) when is_binary(ms) do
    case Integer.parse(ms) do
      {n, _} -> n |> DateTime.from_unix!(:millisecond) |> DateTime.truncate(:second)
      _ -> nil
    end
  end

  defp at_datetime(_), do: nil

  defp at_iso(%DateTime{} = dt, _fallback), do: DateTime.to_iso8601(dt)
  defp at_iso(nil, fallback), do: to_string(fallback)
end
