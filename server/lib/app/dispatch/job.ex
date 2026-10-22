defmodule App.Dispatch.Job do
  @moduledoc "One Claude dispatch job: an issue handed to the CT 109 runner, and how it ended."
  use Ecto.Schema

  schema "dispatch_jobs" do
    belongs_to :user, App.Users.User
    field :repo, :string
    field :issue, :integer
    field :run_id, :integer
    field :run_number, :integer
    field :run_url, :string
    field :status, :string, default: "queued"
    field :branch, :string
    field :pr_url, :string
    field :summary, :string
    field :reason, :string
    field :notified_at, :utc_datetime
    # The watchdog's first failed run read in an unbroken streak (nil after a good one).
    field :read_error_since, :utc_datetime

    timestamps(type: :utc_datetime)
  end
end
