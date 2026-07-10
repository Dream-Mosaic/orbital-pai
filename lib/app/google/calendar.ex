defmodule App.Google.Calendar do
  @moduledoc """
  Google Calendar API client. `list_events/2` reads the account's primary calendar over a time
  window (normalized event maps tagged with the account label); `create_event/2` inserts an
  event on the primary calendar. Both use `Accounts.valid_access_token/1`, so an expired token
  is refreshed transparently.
  """
  alias App.Google.Accounts

  @events_url "https://www.googleapis.com/calendar/v3/calendars/primary/events"

  @doc """
  List events between `:time_min` and `:time_max` (ISO8601 strings) on the account's primary
  calendar. Returns `{:ok, [event]}` | `{:error, reason | :needs_reconnect}`.
  """
  def list_events(account, opts) do
    with {:ok, token} <- Accounts.valid_access_token(account),
         {:ok, items} <- fetch(token, opts) do
      {:ok, Enum.map(items, &normalize(&1, account.label))}
    end
  end

  @doc """
  Create an event on the account's primary calendar. `attrs` is
  `%{summary, start, end, all_day?, location}` (ISO8601 strings; dates for all-day). Returns
  `{:ok, %{summary, start, end, account, html_link}}` | `{:error, :needs_write_access | reason}`.
  """
  def create_event(account, attrs) do
    with {:ok, token} <- Accounts.valid_access_token(account),
         {:ok, body} <- insert(token, event_body(attrs)) do
      {:ok, normalize_created(body, account.label)}
    end
  end

  defp insert(token, event_body) do
    req_opts =
      [
        json: event_body,
        auth: {:bearer, token},
        finch: App.Finch,
        receive_timeout: 6_000
      ] ++ App.Http.Retry.opts() ++ Application.get_env(:app, :google_req_opts, [])

    case Req.post(@events_url, req_opts) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %{status: 403}} -> {:error, :needs_write_access}
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp event_body(%{all_day?: true} = a),
    do: base_body(a) |> Map.merge(%{start: %{date: a.start}, end: %{date: a.end}})

  defp event_body(a),
    do: base_body(a) |> Map.merge(%{start: %{dateTime: a.start}, end: %{dateTime: a.end}})

  defp base_body(a) do
    %{summary: a.summary}
    |> put_unless_nil(:location, Map.get(a, :location))
  end

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)

  defp normalize_created(body, label) do
    {start, _} = edge(body["start"])
    {finish, _} = edge(body["end"])

    %{
      summary: body["summary"],
      start: start,
      end: finish,
      account: label,
      html_link: body["htmlLink"]
    }
  end

  defp fetch(token, opts) do
    params = [
      timeMin: Keyword.fetch!(opts, :time_min),
      timeMax: Keyword.fetch!(opts, :time_max),
      singleEvents: true,
      orderBy: "startTime",
      maxResults: Keyword.get(opts, :max_results, 20)
    ]

    req_opts =
      [
        params: params,
        auth: {:bearer, token},
        finch: App.Finch,
        receive_timeout: 6_000
      ] ++
        App.Http.Retry.opts() ++
        Application.get_env(:app, :google_req_opts, [])

    case Req.get(@events_url, req_opts) do
      {:ok, %{status: 200, body: %{"items" => items}}} -> {:ok, items}
      {:ok, %{status: 200}} -> {:ok, []}
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize(item, label) do
    {start, all_day?} = edge(item["start"])
    {finish, _} = edge(item["end"])

    %{
      id: item["id"],
      summary: item["summary"] || "(no title)",
      start: start,
      end: finish,
      location: item["location"],
      description: item["description"],
      attendees: attendee_emails(item["attendees"]),
      html_link: item["htmlLink"],
      all_day?: all_day?,
      account: label
    }
  end

  defp attendee_emails(list) when is_list(list),
    do: for(a <- list, e = a["email"], is_binary(e), do: e)

  defp attendee_emails(_), do: []

  # Timed events carry "dateTime"; all-day events carry "date".
  defp edge(%{"dateTime" => dt}), do: {dt, false}
  defp edge(%{"date" => d}), do: {d, true}
  defp edge(_), do: {nil, false}

  @doc false
  def format_when(%DateTime{} = dt) do
    case DateTime.shift_zone(dt, App.Config.timezone()) do
      {:ok, local} -> Calendar.strftime(local, "%a %b %-d, %Y %-I:%M %p %Z")
      _ -> Calendar.strftime(dt, "%a %b %-d, %Y %-I:%M %p UTC")
    end
  end
end
