defmodule App.Google.Gmail do
  @moduledoc """
  Gmail REST API client. `list_messages/2` searches a mailbox (Gmail `q` syntax) and fans out to
  per-message metadata; `get_message/2` reads one message's full plaintext body; `send_message/2`
  sends a message (threaded when `:reply_to_id` is given). All use `Accounts.valid_access_token/1`,
  so an expired token refreshes transparently. Req options are overridable via `:google_req_opts`
  (test seam, same as `App.Google.Calendar`).
  """
  require Logger
  alias App.Google.Accounts
  alias App.Google.Gmail.{Body, Mime}

  @base "https://gmail.googleapis.com/gmail/v1/users/me"

  @doc """
  Search messages. `opts`: `:q` (Gmail query, default `"is:unread in:inbox"`), `:max_results`
  (default 10). Returns `{:ok, [%{id, from, subject, date, snippet, internal_date}]}` |
  `{:error, reason | :needs_reconnect}`. The list endpoint returns ids only, so each id is then
  fetched for metadata concurrently.
  """
  def list_messages(account, opts \\ []) do
    q = Keyword.get(opts, :q, "is:unread in:inbox")
    max = Keyword.get(opts, :max_results, 10)

    with {:ok, token} <- Accounts.valid_access_token(account),
         {:ok, ids} <- list_ids(token, q, max) do
      {:ok, fetch_metadata(token, ids)}
    end
  end

  @doc """
  List message ids matching a Gmail query — ids only, no per-message metadata fan-out (the semantic
  indexer only needs ids to diff; it fetches full bodies for *new* ids). `opts`: `:q`, `:max_results`
  (default 100). Returns `{:ok, [id]}` | `{:error, reason | :needs_reconnect}`.
  """
  def list_message_ids(account, opts \\ []) do
    q = Keyword.get(opts, :q, "in:inbox")
    max = Keyword.get(opts, :max_results, 100)

    with {:ok, token} <- Accounts.valid_access_token(account) do
      list_ids(token, q, max)
    end
  end

  @doc """
  Read one message's full plaintext body. Returns
  `{:ok, %{from, subject, date, body}}` | `{:error, reason | :needs_reconnect}`.
  """
  def get_message(account, id) do
    with {:ok, token} <- Accounts.valid_access_token(account),
         {:ok, body} <- get(token, id, format: "full") do
      {:ok,
       %{
         from: header(body, "From"),
         subject: header(body, "Subject"),
         date: header(body, "Date"),
         internal_date: body["internalDate"],
         body: Body.extract(body["payload"] || %{})
       }}
    end
  end

  @doc """
  Send a message. `attrs`: `%{to, subject, body}` plus optional `:reply_to_id` (a raw message id
  to thread onto). Returns `{:ok, %{to, subject, account}}` |
  `{:error, :needs_write_access | reason | :needs_reconnect}`.
  """
  def send_message(account, attrs) do
    with {:ok, token} <- Accounts.valid_access_token(account) do
      {mime_attrs, thread_id} = prepare(token, account, attrs)
      payload = %{raw: Mime.encode(mime_attrs)}
      payload = if thread_id, do: Map.put(payload, :threadId, thread_id), else: payload

      case post_send(token, payload) do
        :ok -> {:ok, %{to: attrs.to, subject: mime_attrs.subject, account: account.label}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # --- list ---

  defp list_ids(token, q, max) do
    case Req.get("#{@base}/messages", req_opts(token, params: [q: q, maxResults: max])) do
      {:ok, %{status: 200, body: %{"messages" => msgs}}} -> {:ok, Enum.map(msgs, & &1["id"])}
      {:ok, %{status: 200}} -> {:ok, []}
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_metadata(token, ids) do
    ids
    |> Task.async_stream(fn id -> metadata(token, id) end,
      max_concurrency: 5,
      # innermost layer of the search_email budget (per-account gather 15s, tool cap 18s). Cold
      # metadata fan-out over many ids can be slow; give it room rather than dropping messages.
      timeout: 12_000,
      on_timeout: :kill_task
    )
    |> Enum.flat_map(fn
      {:ok, {:ok, msg}} ->
        [msg]

      {:ok, {:error, reason}} ->
        Logger.debug("[gmail] message metadata fetch failed: #{inspect(reason)}")
        []

      _ ->
        []
    end)
  end

  defp metadata(token, id) do
    case get(token, id, format: "metadata") do
      {:ok, body} ->
        {:ok,
         %{
           id: id,
           from: header(body, "From"),
           subject: header(body, "Subject"),
           date: header(body, "Date"),
           snippet: body["snippet"],
           internal_date: body["internalDate"]
         }}

      error ->
        error
    end
  end

  # --- get ---

  defp get(token, id, params) do
    case Req.get("#{@base}/messages/#{id}", req_opts(token, params: params)) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  # --- send ---

  # Plain send: no threading. Reply: fetch the original's Message-ID/References/Subject/threadId.
  defp prepare(_token, account, %{reply_to_id: nil} = attrs),
    do: {plain_attrs(account, attrs), nil}

  defp prepare(token, account, %{reply_to_id: id} = attrs) when is_binary(id) do
    case get(token, id, format: "metadata") do
      {:ok, original} ->
        mid = header(original, "Message-ID") || header(original, "Message-Id")
        refs = header(original, "References")
        subject = attrs[:subject] || re_subject(header(original, "Subject"))

        {%{
           from: account.email,
           to: attrs.to,
           subject: subject,
           body: attrs.body,
           in_reply_to: mid,
           references: if(mid && refs, do: "#{refs} #{mid}", else: mid)
         }, original["threadId"]}

      _ ->
        # Couldn't read the original — fall back to a plain (non-threaded) send.
        {plain_attrs(account, attrs), nil}
    end
  end

  defp prepare(_token, account, attrs), do: {plain_attrs(account, attrs), nil}

  defp plain_attrs(account, attrs) do
    %{from: account.email, to: attrs.to, subject: attrs[:subject] || "", body: attrs.body}
  end

  defp re_subject(nil), do: "Re:"

  defp re_subject(subject) do
    if subject |> String.downcase() |> String.starts_with?("re:"),
      do: subject,
      else: "Re: #{subject}"
  end

  defp post_send(token, payload) do
    case Req.post("#{@base}/messages/send", req_opts(token, json: payload)) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: 403}} -> {:error, :needs_write_access}
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  # --- shared ---

  defp header(%{"payload" => %{"headers" => headers}}, name) when is_list(headers),
    do: find_header(headers, name)

  defp header(_, _), do: nil

  defp find_header(headers, name) do
    down = String.downcase(name)

    Enum.find_value(headers, fn h ->
      if String.downcase(h["name"] || "") == down, do: h["value"]
    end)
  end

  defp req_opts(token, extra) do
    [auth: {:bearer, token}, finch: App.Finch, receive_timeout: 6_000] ++
      App.Http.Retry.opts() ++ extra ++ Application.get_env(:app, :google_req_opts, [])
  end
end
