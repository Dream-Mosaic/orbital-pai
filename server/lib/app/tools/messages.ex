defmodule App.Tools.Messages do
  @moduledoc """
  Household messages (the intercom): `send_household_message` relays something to another
  allowlisted member of the household — spoken on their device now if they're connected, or the
  next time they talk to Henry; `check_household_messages` reads back what I've sent (delivered
  or still waiting) and how many are waiting for me. See `App.Messages`.

  Every user-facing outcome — including a name nobody answers to — is an `{:ok, %{sent: false,
  error: …}}` the brain can say out loud; `{:error, _}` is reserved for malformed calls.
  """
  @behaviour App.Tools.Tool

  alias App.Messages
  alias App.Messages.Message

  @impl true
  def declarations do
    [
      %{
        name: "send_household_message",
        description:
          "Relay a short message to another person in the household (\"tell Tanya dinner's " <>
            "ready\"). Henry speaks it on their device right away if they're around, otherwise " <>
            "the next time they talk to Henry. Only when the user clearly asks.",
        parameters: %{
          type: "object",
          properties: %{
            to: %{
              type: "string",
              description: "Who it's for: the household member's name (e.g. \"Tanya\")."
            },
            message: %{
              type: "string",
              description:
                "The message exactly as the recipient should HEAR it, short and natural — " <>
                  "first person from the sender is fine (\"dinner's ready, come on down\"). " <>
                  "Don't add who it's from; Henry says that."
            }
          },
          required: ["to", "message"]
        }
      },
      %{
        name: "check_household_messages",
        description:
          "Check on household messages: the user's recently sent ones (delivered or still " <>
            "waiting) and how many are waiting for the user.",
        parameters: %{type: "object", properties: %{}, required: []}
      }
    ]
  end

  @impl true
  def prompt do
    "Household messages: when the user asks you to tell, let know, or leave a message for " <>
      "someone else in the household (\"tell Tanya dinner's ready\", \"let David know I'm " <>
      "running late\"), call send_household_message with their name and the message phrased " <>
      "the way THEY should hear it — first person from the sender is fine (\"dinner's ready, " <>
      "come on down\"). Then confirm in a few words from the result's delivery: \"now\" → " <>
      "\"Told her.\"; \"next_time\" → \"I'll pass it on next time she's around.\" If it comes " <>
      "back sent: false, say why using its error. Never send a message unless the user clearly " <>
      "asked you to. A \"(message from …)\" line in the history is one you relayed TO this " <>
      "user — \"tell him I'm coming\" goes back to its sender. \"Did Tanya get my message?\" " <>
      "or \"any messages for me?\" → check_household_messages."
  end

  @impl true
  def bridge(_name), do: []

  @impl true
  def execute("send_household_message", _args, %{user_id: nil}),
    do: {:ok, %{sent: false, error: "no user session — message not sent"}}

  def execute("send_household_message", %{"to" => to, "message" => body}, ctx)
      when is_binary(to) do
    case Messages.send_message(ctx.user_id, to, body) do
      {:ok, %{recipient_name: name, live?: live?}} ->
        {:ok, %{sent: true, to: name, delivery: if(live?, do: "now", else: "next_time")}}

      {:error, {:unknown_recipient, names}} ->
        {:ok,
         %{
           sent: false,
           error: "No one in the household goes by #{inspect(to)}.",
           household: names
         }}

      {:error, :self} ->
        {:ok,
         %{
           sent: false,
           error: "Can't send a message to yourself — it goes to someone else in the household."
         }}

      {:error, :blank} ->
        {:ok, %{sent: false, error: "The message was empty."}}

      {:error, :too_long} ->
        {:ok,
         %{
           sent: false,
           error: "Too long to relay — keep it under #{Message.max_body()} characters."
         }}

      {:error, _} ->
        {:ok, %{sent: false, error: "Couldn't save the message."}}
    end
  end

  def execute("send_household_message", _args, _ctx), do: {:error, :missing_args}

  def execute("check_household_messages", _args, %{user_id: nil}),
    do: {:ok, %{sent: [], waiting_for_you: 0}}

  def execute("check_household_messages", _args, ctx),
    do: {:ok, Messages.recent_status(ctx.user_id)}
end
