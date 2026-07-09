defmodule App.Tools.Gmail do
  @moduledoc """
  The Gmail tools. `search_email` reads the user's connected Google accounts (Gmail `q` syntax,
  defaulting to unread inbox), fans out concurrently, merges + sorts by recency, and tags each
  message with an opaque `handle` ("<account label>:<message id>") plus a snippet. `read_email`
  fetches one message's full plaintext body by handle, to read aloud. `send_email` sends a message
  (confirm-first via the prompt), optionally threading a reply via `reply_to`.
  """
  @behaviour App.Tools.Tool

  require Logger
  alias App.Google.{Accounts, Connectors, Gmail}
  # Reuse the calendar tool's tested, case-insensitive account matcher.
  alias App.Tools.Calendar

  # Cap a read body so a giant newsletter can't monopolize a turn (chars).
  @max_body 2_000

  @impl true
  def declarations do
    [
      %{
        name: "search_email",
        description:
          "Search the user's Gmail across their connected Google accounts. `query` uses Gmail " <>
            "search syntax (e.g. `from:alice newer_than:7d`, `subject:invoice`); OMIT it to get " <>
            "unread inbox mail (defaults to `is:unread in:inbox`). Returns each message's sender, " <>
            "subject, a short snippet, and an opaque `handle` — pass that handle to `read_email` " <>
            "to read the full message or to `send_email`'s `reply_to` to reply. `accounts_read` " <>
            "lists every connected account checked. Account names match case-insensitively.",
        parameters: %{
          type: "object",
          properties: %{
            query: %{
              type: "string",
              description: "Gmail search query; omit for unread inbox (`is:unread in:inbox`)."
            },
            account: %{
              type: "string",
              description: "Limit to one connected account by email/label; omit for all."
            }
          },
          required: []
        }
      },
      %{
        name: "read_email",
        description:
          "Read one email's full plaintext body aloud. `handle` is the opaque id returned by " <>
            "`search_email`. Long bodies are truncated (a `truncated` flag says so).",
        parameters: %{
          type: "object",
          properties: %{
            handle: %{type: "string", description: "A message handle from search_email."}
          },
          required: ["handle"]
        }
      },
      %{
        name: "send_email",
        description:
          "Send an email. First read the recipient, subject, and body back to the user and wait " <>
            "for them to confirm; only then call this. To reply within a thread, pass the original " <>
            "message's `handle` as `reply_to` (the reply is sent from that message's account and " <>
            "the subject defaults to `Re: …`). Otherwise it sends from the default account unless " <>
            "`account` is given.",
        parameters: %{
          type: "object",
          properties: %{
            to: %{type: "string", description: "Recipient email address."},
            subject: %{type: "string", description: "Subject line. Optional for a reply."},
            body: %{type: "string", description: "Plaintext message body."},
            reply_to: %{
              type: "string",
              description: "A message handle from search_email to thread this as a reply."
            },
            account: %{
              type: "string",
              description: "Send from this account by email/label; omit for default."
            }
          },
          required: ["to", "body"]
        }
      }
    ]
  end

  # Gmail is multi-account + multi-roundtrip (list, then per-message metadata fan-out), so it needs
  # a bigger cap than the 8s default — especially cold. Safe now that the TTS context is kept alive
  # while it runs (BrainStream keepalive). These bound the layered fetch (see App.Google.Gmail and
  # the gather/2 fan-out below): tool cap > per-account gather > per-message metadata.
  @impl true
  def timeout("search_email"), do: 18_000
  def timeout("read_email"), do: 12_000
  def timeout("send_email"), do: 12_000
  def timeout(_), do: 8_000

  @impl true
  def cache_ttl("search_email"), do: 15_000
  def cache_ttl(_), do: nil

  @impl true
  def cache_invalidates("send_email"), do: ["search_email"]
  def cache_invalidates(_), do: []

  @impl true
  def bridge("search_email"),
    do: ["Checking your email, one moment.", "Let me look at your inbox."]

  def bridge("read_email"), do: ["Opening that email.", "One sec, pulling it up."]
  def bridge("send_email"), do: ["Sending that now.", "Firing off that email."]
  def bridge(_), do: []

  # --- search_email ---

  @impl true
  def execute("search_email", _args, %{user_id: nil}),
    do: {:ok, %{messages: [], note: note(nil)}}

  def execute("search_email", args, %{user_id: user_id}) do
    filter = Map.get(args, "account")
    query = Map.get(args, "query") || "is:unread in:inbox"

    case select_accounts(user_id, filter) do
      [] ->
        {:ok, %{messages: [], note: note(filter)}}

      accounts ->
        accounts = ensure_fresh(user_id, accounts)
        {messages, errors} = gather(accounts, query)

        {:ok,
         %{messages: messages, errors: errors, accounts_read: Enum.map(accounts, & &1.label)}}
    end
  end

  def execute("read_email", _args, %{user_id: nil}),
    do: {:ok, %{note: note(nil)}}

  def execute("read_email", args, %{user_id: user_id}) do
    case resolve_handle(user_id, Map.get(args, "handle")) do
      {:ok, account, id} ->
        case Gmail.get_message(account, id) do
          {:ok, msg} -> {:ok, %{message: cap_body(msg)}}
          {:error, :needs_reconnect} -> {:ok, %{error: "needs_reconnect", account: account.label}}
          {:error, reason} -> {:error, reason}
        end

      {:error, note} ->
        {:ok, %{note: note}}
    end
  end

  def execute("send_email", _args, %{user_id: nil}),
    do: {:ok, %{note: note(nil)}}

  def execute("send_email", args, %{user_id: user_id}) do
    cond do
      blank?(Map.get(args, "to")) -> {:ok, %{note: "missing recipient (to)"}}
      blank?(Map.get(args, "body")) -> {:ok, %{note: "missing body"}}
      true -> do_send(user_id, args)
    end
  end

  # --- send helpers ---

  defp do_send(user_id, %{"reply_to" => handle} = args)
       when is_binary(handle) and handle != "" do
    case resolve_handle(user_id, handle) do
      {:ok, account, id} ->
        dispatch_send(account, send_attrs(args, id))

      {:error, note} ->
        {:ok, %{note: note}}
    end
  end

  defp do_send(user_id, args) do
    case resolve_target(user_id, Map.get(args, "account")) do
      {:ok, account} -> dispatch_send(account, send_attrs(args, nil))
      {:error, note} -> {:ok, %{note: note}}
    end
  end

  defp send_attrs(args, reply_to_id) do
    %{
      to: Map.get(args, "to"),
      subject: Map.get(args, "subject"),
      body: Map.get(args, "body"),
      reply_to_id: reply_to_id
    }
  end

  defp dispatch_send(account, attrs) do
    case Gmail.send_message(account, attrs) do
      {:ok, sent} ->
        {:ok, %{sent: sent}}

      {:error, :needs_write_access} ->
        {:ok, %{error: "needs_write_access", account: account.label}}

      {:error, :needs_reconnect} ->
        {:ok, %{error: "needs_reconnect", account: account.label}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # No name: prefer the default if it can send, else the sole sender, else ask.
  defp resolve_target(user_id, nil) do
    senders = Accounts.accounts_with_write(user_id, :gmail)
    default = Accounts.default(user_id)

    cond do
      default && Connectors.can_write?(default, :gmail) ->
        {:ok, default}

      match?([_one], senders) ->
        {:ok, hd(senders)}

      senders == [] ->
        if Accounts.list(user_id) == [],
          do: {:error, "no Google accounts connected"},
          else: {:error, "no Gmail account with send access — connect one or grant send"}

      true ->
        {:error, "multiple Gmail accounts — name which account to send from"}
    end
  end

  # Named: must exist and be able to send.
  defp resolve_target(user_id, filter) do
    case Enum.find(Accounts.list(user_id), &Calendar.account_matches?(&1, filter)) do
      nil ->
        {:error, "no connected account matching #{inspect(filter)}"}

      account ->
        if Connectors.can_write?(account, :gmail),
          do: {:ok, account},
          else: {:error, "#{account.label} is read-only for Gmail (no send access)"}
    end
  end

  # --- shared helpers ---

  defp select_accounts(user_id, nil), do: Accounts.accounts_with_read(user_id, :gmail)

  defp select_accounts(user_id, filter),
    do:
      Enum.filter(
        Accounts.accounts_with_read(user_id, :gmail),
        &Calendar.account_matches?(&1, filter)
      )

  # Refresh tokens SEQUENTIALLY before the concurrent fetch — same SQLite single-writer fix as
  # App.Tools.Calendar (concurrent refresh contends for the single writer and times out the fan-out).
  defp ensure_fresh(user_id, accounts) do
    Enum.each(accounts, &Accounts.valid_access_token/1)
    ids = MapSet.new(accounts, & &1.id)
    Enum.filter(Accounts.list(user_id), &MapSet.member?(ids, &1.id))
  end

  defp gather(accounts, query) do
    results =
      accounts
      |> Task.async_stream(fn a -> Gmail.list_messages(a, q: query) end,
        max_concurrency: 5,
        # under the 18s search_email tool cap, above the 12s per-message metadata fan-out — so a
        # single slow account is isolated/killed here, leaving the others' results intact.
        timeout: 15_000,
        on_timeout: :kill_task
      )
      |> Enum.to_list()

    {messages, errors} =
      Enum.reduce(Enum.zip(accounts, results), {[], []}, fn
        {a, {:ok, {:ok, msgs}}}, {acc_msgs, errs} ->
          {tag(msgs, a) ++ acc_msgs, errs}

        {a, {:ok, {:error, reason}}}, {acc_msgs, errs} ->
          Logger.warning("[gmail] #{a.label} search failed: #{inspect(reason)}")
          {acc_msgs, [%{account: a.label, reason: error_reason(reason)} | errs]}

        {a, {:exit, _}}, {acc_msgs, errs} ->
          Logger.warning("[gmail] #{a.label} search timed out (>15s)")
          {acc_msgs, [%{account: a.label, reason: "timeout"} | errs]}
      end)

    {messages |> Enum.sort_by(&sort_key/1, :desc) |> Enum.map(&strip_sort_key/1),
     Enum.reverse(errors)}
  end

  # Tag each message with its account label + opaque handle; keep internal_date for sorting.
  defp tag(msgs, account) do
    Enum.map(msgs, fn m ->
      %{
        handle: "#{account.label}:#{m.id}",
        from: m.from,
        subject: m.subject,
        date: m.date,
        snippet: m.snippet,
        account: account.label,
        internal_date: m.internal_date
      }
    end)
  end

  # internalDate is a ms-epoch string; parse for chronological sort, missing sorts oldest.
  defp sort_key(%{internal_date: d}) when is_binary(d) do
    case Integer.parse(d) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp sort_key(_), do: 0

  defp strip_sort_key(m), do: Map.delete(m, :internal_date)

  defp resolve_handle(user_id, handle) when is_binary(handle) and handle != "" do
    # Handles are "<label>:<id>", split on the FIRST colon only. Gmail message ids carry no colon;
    # a label containing a colon is the one shape this can't round-trip (acceptable for now).
    case String.split(handle, ":", parts: 2) do
      [label, id] when id != "" ->
        match =
          Enum.find(
            Accounts.accounts_with_read(user_id, :gmail),
            &(String.downcase(&1.label) == String.downcase(label))
          )

        if match,
          do: {:ok, match, id},
          else: {:error, "no connected Gmail account for #{inspect(label)}"}

      _ ->
        {:error, "bad message handle #{inspect(handle)}"}
    end
  end

  defp resolve_handle(_user_id, _), do: {:error, "missing message handle"}

  defp cap_body(%{body: body} = msg) when is_binary(body) do
    if String.length(body) > @max_body do
      %{msg | body: String.slice(body, 0, @max_body) <> "…"}
      |> Map.put(:truncated, true)
    else
      Map.put(msg, :truncated, false)
    end
  end

  defp cap_body(msg), do: Map.put(msg, :truncated, false)

  defp error_reason(:needs_reconnect), do: "needs_reconnect"
  defp error_reason(other), do: inspect(other)

  defp note(nil), do: "no Google accounts connected"
  defp note(filter), do: "no connected account matching #{inspect(filter)}"

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(v) when is_binary(v), do: false
  defp blank?(_), do: true
end
