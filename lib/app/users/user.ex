defmodule App.Users.User do
  @moduledoc "A person who uses the app. Identity only; connections live elsewhere."
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :email, :string
    field :name, :string
    field :default_abi, :boolean, default: false
    field :default_ptt, :boolean, default: false
    field :voice_activation, :boolean, default: false
    field :relock_seconds, :integer, default: 15
    # morning briefing: local "HH:MM" (nil = off) + the local date last DELIVERED (once/day)
    field :briefing_time, :string
    field :briefing_last_on, :date
    # Voice Lock: "off" | "shadow" | "enforce"; nil threshold falls back to App.Config.
    field :voice_lock_mode, :string, default: "off"
    field :voice_lock_threshold, :float
    # Books nav: the remembered picker selection — "list:<id>" or "garden"; nil = never chosen
    # (falls back to the household groceries list, else the first book, else Garden).
    field :books_last_book, :string
    timestamps(type: :utc_datetime)
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :name])
    |> validate_required([:email, :name])
    |> unique_constraint(:email)
  end

  @doc false
  def prefs_changeset(user, attrs) do
    user
    |> cast(attrs, [
      :default_abi,
      :default_ptt,
      :voice_activation,
      :relock_seconds,
      :briefing_time,
      :voice_lock_mode,
      :voice_lock_threshold,
      :books_last_book
    ])
    |> validate_format(:briefing_time, ~r/^\d{2}:\d{2}$/, message: "must be HH:MM (24h)")
    |> validate_inclusion(:voice_lock_mode, ~w(off shadow enforce))
    |> validate_number(:voice_lock_threshold,
      greater_than: -1.0,
      less_than: 1.0,
      message: "must be a cosine in (-1, 1)"
    )
  end

  @doc "Set or clear the briefing time. nil turns the briefing off."
  def set_briefing_time(user, nil), do: Ecto.Changeset.change(user, briefing_time: nil)
  def set_briefing_time(user, hhmm), do: prefs_changeset(user, %{briefing_time: hhmm})
end
