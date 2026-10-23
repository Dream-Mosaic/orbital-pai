defmodule App.LogText do
  @moduledoc """
  What people say, in a log line.

  Dev and test log it verbatim; production (`config :app, log_speech: false` in prod.exs) logs
  only its length, so transcripts, typed text, calendar titles and tool arguments never reach the
  log store. The turns themselves are in SQLite and the admin dashboard.
  """

  @spec said(term()) :: String.t()
  def said(term) do
    if Application.get_env(:app, :log_speech, true) do
      inspect(term)
    else
      redact(term)
    end
  end

  defp redact(term) when is_binary(term), do: "‹#{String.length(term)} chars›"
  defp redact(_term), do: "‹redacted›"
end
