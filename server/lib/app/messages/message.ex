defmodule App.Messages.Message do
  @moduledoc """
  A household message: one allowlisted user asking Henry to tell another something. `body` is
  what the recipient HEARS (spoken verbatim as a canned agenda item); `delivered_at` stamps the
  moment the recipient's Conversation started speaking it — nil = still waiting for them.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias App.Users.User

  @max_body 500

  schema "household_messages" do
    belongs_to :from_user, User
    belongs_to :to_user, User
    field :body, :string
    field :delivered_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  @doc "The longest body a message may carry (characters)."
  def max_body, do: @max_body

  def changeset(message, attrs) do
    message
    |> cast(attrs, [:from_user_id, :to_user_id, :body])
    |> update_change(:body, &String.trim/1)
    |> validate_required([:from_user_id, :to_user_id, :body])
    |> validate_length(:body, max: @max_body)
    |> foreign_key_constraint(:from_user_id)
    |> foreign_key_constraint(:to_user_id)
  end
end
