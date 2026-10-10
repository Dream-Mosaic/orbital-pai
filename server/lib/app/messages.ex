defmodule App.Messages do
  @moduledoc """
  Household messages (the intercom): "Henry, tell Tanya dinner's ready". The sender's brain
  calls `send_message/3`; the message is stored, then delivered as a CANNED agenda item on the
  recipient's `"agenda:<user_id>"` topic — spoken verbatim on her device right now if her
  Conversation is up, or picked up by `pull/1` the next time one starts (pull-on-connect, like
  the morning briefing). `delivered_at` is stamped by the item's `ack`, i.e. when her
  Conversation starts speaking it, so a message is never marked heard before it is said.

  Recipients are the OTHER allowlisted users, resolved by `App.Messages.Recipient` (first name,
  full name, email local part, aliases). Not gated on `household_named_targets`: a message is a
  communication, not a write into someone else's data. Spec: 2026-10-10 household wave 1, F4.
  """
  import Ecto.Query
  require Logger

  alias App.Agenda
  alias App.Agenda.Item
  alias App.Conversations.Sessions
  alias App.Messages.{Message, Recipient}
  alias App.Repo
  alias App.Users

  @recent_sent 5

  @doc """
  Send `body` from `from_user_id` to the household member `to` names.

  `{:ok, %{message, recipient_name, live?}}` — `live?` says whether she's around right now (a
  live Conversation with a connected device), so the brain can say "told her" vs "I'll pass it
  on". Errors: `{:error, {:unknown_recipient, valid_first_names}}`, `{:error, :self}`,
  `{:error, :blank}`, `{:error, :too_long}` (over #{Message.max_body()} characters).
  """
  def send_message(from_user_id, to, body) do
    with {:ok, recipient} <- resolve(from_user_id, to),
         {:ok, body} <- check_body(body),
         {:ok, message} <- insert(from_user_id, recipient.id, body) do
      Logger.info("[messages] ##{message.id} user #{from_user_id} → user #{recipient.id}")
      message = Repo.preload(message, :from_user)
      Agenda.deliver(recipient.id, item(message))

      {:ok,
       %{
         message: message,
         recipient_name: Recipient.first_name(recipient),
         live?: recipient_live?(recipient.id)
       }}
    end
  end

  defp resolve(from_user_id, to) do
    users = Enum.filter(Users.list(), &Users.allowed?(&1.email))
    Recipient.resolve(to, from_user_id, users, Users.allowlist())
  end

  defp check_body(body) when is_binary(body) do
    body = String.trim(body)

    cond do
      body == "" -> {:error, :blank}
      String.length(body) > Message.max_body() -> {:error, :too_long}
      true -> {:ok, body}
    end
  end

  defp check_body(_), do: {:error, :blank}

  defp insert(from_id, to_id, body) do
    %Message{}
    |> Message.changeset(%{from_user_id: from_id, to_user_id: to_id, body: body})
    |> Repo.insert()
  end

  @doc """
  Is `user_id` around to hear a message right now? Their Conversation is alive (the Registry)
  AND a device of theirs is connected (voice Presence). The second half matters: a session
  outlives its device by the client linger (~2 min), and a message spoken into that gap would be
  heard by no one — the Conversation holds it instead (see its `{:agenda_due, _}` handler), so
  the honest answer is "next time".
  """
  def recipient_live?(user_id) do
    key = to_string(user_id)

    match?({:ok, _}, Sessions.lookup(key)) and
      Map.has_key?(AppWeb.Presence.list("presence:voice"), key)
  end

  @doc """
  The canned agenda item that speaks `message` to its recipient: a lead naming the sender, then
  the body verbatim (no model call). Persisted as "(message from David: …)" so a reply ("tell him
  I'm on my way") has context; the ack stamps `delivered_at`. Never expires.
  """
  def item(%Message{} = message) do
    message = Repo.preload(message, :from_user)
    from = Recipient.first_name(message.from_user)

    %Item{
      kind: :message,
      canned: true,
      deliver: :when_idle,
      prompt: speakable(message.body),
      lead_idle: "Message from #{from} —",
      lead_interjected: "Oh — a message from #{from} —",
      persist_as: "(message from #{from}: #{message.body})",
      ack: {__MODULE__, :mark_delivered, [message.id]}
    }
  end

  # TTS wants a sentence end: add a period unless the body already closes with one.
  defp speakable(body) do
    if String.match?(body, ~r/[.!?…]["'”’)\]]*$/u), do: body, else: body <> "."
  end

  @doc """
  Stamp a message delivered. Idempotent: only an undelivered row is touched, so the first stamp
  stands. Runs off the FSM (the agenda ack); retried on SQLite busy, since a lost stamp means
  the message is spoken again on her next connect.
  """
  def mark_delivered(id) do
    Users.with_busy_retry(fn ->
      from(m in Message, where: m.id == ^id and is_nil(m.delivered_at))
      |> Repo.update_all(set: [delivered_at: DateTime.utc_now()])
    end)

    :ok
  end

  @doc """
  The session user's undelivered messages as agenda items, oldest first — the Conversation's
  pull-on-connect (`:pull_messages`). Non-user sessions get `[]`. Never raises: a failed read
  costs a delay (the message waits for the next connect), never the session.
  """
  def pull(session_id) do
    case Users.id_from_session(session_id) do
      nil ->
        []

      user_id ->
        from(m in Message,
          where: m.to_user_id == ^user_id and is_nil(m.delivered_at),
          order_by: [asc: m.inserted_at, asc: m.id],
          preload: :from_user
        )
        |> Repo.all()
        |> Enum.map(&item/1)
    end
  rescue
    e ->
      Logger.error("[messages] pull failed: #{inspect(e)}")
      []
  end

  @doc """
  What `check_household_messages` reads back: my last #{@recent_sent} sent messages, newest
  first (`to`, `message`, `sent` "5 minutes ago", `delivered`, `delivered_when`), and how many
  messages are still waiting for me.
  """
  def recent_status(user_id) do
    now = DateTime.utc_now()

    sent =
      from(m in Message,
        where: m.from_user_id == ^user_id,
        order_by: [desc: m.inserted_at, desc: m.id],
        limit: @recent_sent,
        preload: :to_user
      )
      |> Repo.all()
      |> Enum.map(fn m ->
        %{
          to: Recipient.first_name(m.to_user),
          message: m.body,
          sent: ago(m.inserted_at, now),
          delivered: not is_nil(m.delivered_at),
          delivered_when: m.delivered_at && ago(m.delivered_at, now)
        }
      end)

    waiting =
      Repo.aggregate(
        from(m in Message, where: m.to_user_id == ^user_id and is_nil(m.delivered_at)),
        :count
      )

    %{sent: sent, waiting_for_you: waiting}
  end

  @doc false
  # A short, speakable relative time ("just now", "5 minutes ago", "yesterday").
  def ago(%DateTime{} = at, %DateTime{} = now) do
    s = max(DateTime.diff(now, at, :second), 0)

    cond do
      s < 60 -> "just now"
      s < 3600 -> plural(div(s, 60), "minute")
      s < 86_400 -> plural(div(s, 3600), "hour")
      s < 2 * 86_400 -> "yesterday"
      true -> plural(div(s, 86_400), "day")
    end
  end

  defp plural(1, unit), do: "1 #{unit} ago"
  defp plural(n, unit), do: "#{n} #{unit}s ago"
end
