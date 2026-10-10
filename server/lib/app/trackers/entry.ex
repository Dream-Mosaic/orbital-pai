defmodule App.Trackers.Entry do
  @moduledoc """
  One data point on a tracker: WHEN it happened (`recorded_at`, UTC — may be backdated: "I had
  a headache yesterday afternoon"), an optional number (`value`: pain 6, 182.4 lb, 7.5 hours),
  an optional free `note`, and optional short `tags` (likely triggers or context: "skipped
  lunch", "poor sleep"). Every field but `recorded_at` is optional — "I've got a headache" is
  itself the data point. Append-only in spirit: the only edit is undo (delete the last one).
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "tracker_entries" do
    field :recorded_at, :utc_datetime_usec
    field :value, :float
    field :note, :string
    field :tags, {:array, :string}, default: []
    belongs_to :tracker, App.Trackers.Tracker
    timestamps(type: :utc_datetime)
  end

  @fields [:tracker_id, :recorded_at, :value, :note, :tags]

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, @fields)
    |> validate_required([:tracker_id, :recorded_at])
    |> validate_length(:note, max: 2_000)
  end
end
