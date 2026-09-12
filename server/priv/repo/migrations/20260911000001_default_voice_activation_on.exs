defmodule App.Repo.Migrations.DefaultVoiceActivationOn do
  use Ecto.Migration

  # The schema default only reaches NEW rows. Existing users are exactly the people paying for
  # continuous streaming, so they are the ones who must be flipped.
  def up, do: execute("UPDATE users SET voice_activation = 1 WHERE voice_activation = 0")

  # Deliberately a no-op: we cannot distinguish rows we flipped from rows the user had already
  # turned on, and guessing would silently switch someone's setting back.
  def down, do: :ok
end
