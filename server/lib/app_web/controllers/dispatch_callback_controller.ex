defmodule AppWeb.DispatchCallbackController do
  @moduledoc """
  HMAC-signed status callback from the claude-dispatch workflow. Never logs body/signature.

  Only the signed JSON body counts (`conn.body_params`): the query string isn't covered by the
  signature, so nothing is read from it. A body that names a `repo` or `issue` must name the
  job's own, or the callback is refused like a bad signature (401).
  """
  use AppWeb, :controller
  require Logger

  alias App.Dispatch

  def create(conn, _params) do
    params = conn.body_params

    with :ok <- verify(conn),
         {:ok, job} <- find_job(params),
         :ok <- same_job(job, params),
         {:ok, status} <- status(params) do
      case Dispatch.apply_callback(job, Map.put(params, "status", status)) do
        {:ok, _job, _changed} -> send_resp(conn, 204, "")
        _ -> send_resp(conn, 422, "")
      end
    else
      {:reject, why} ->
        Logger.warning("[dispatch] callback rejected (#{why})")
        send_resp(conn, 401, "")

      :invalid ->
        send_resp(conn, 422, "")
    end
  end

  defp verify(conn) do
    secret = Application.get_env(:app, :dispatch_callback_secret)
    raw = conn.assigns[:raw_body]

    sig =
      case Plug.Conn.get_req_header(conn, "x-dispatch-signature") do
        [s | _] -> s
        _ -> nil
      end

    cond do
      not is_binary(secret) or secret == "" -> {:reject, "no secret configured"}
      is_nil(sig) -> {:reject, "no signature"}
      not is_binary(raw) -> {:reject, "no body"}
      Plug.Crypto.secure_compare(expected(secret, raw), sig) -> :ok
      true -> {:reject, "bad signature"}
    end
  end

  defp expected(secret, raw),
    do: "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, secret, raw), case: :lower)

  defp find_job(%{"job_id" => id}) when is_binary(id) or is_integer(id) do
    with {int, ""} <- Integer.parse(to_string(id)),
         %Dispatch.Job{} = job <- Dispatch.get_job(int) do
      {:ok, job}
    else
      _ -> {:reject, "unknown job"}
    end
  end

  defp find_job(%{"job_id" => _}), do: {:reject, "unknown job"}
  defp find_job(_), do: :invalid

  # The box echoes the repo and issue it was dispatched with; a signed callback for job 42 that
  # names another issue is a wiring bug (or a replayed body), never something to apply.
  defp same_job(job, params) do
    if repo_matches?(params["repo"], job.repo) and issue_matches?(params["issue"], job.issue),
      do: :ok,
      else: {:reject, "job mismatch"}
  end

  defp repo_matches?(nil, _), do: true
  defp repo_matches?(r, repo) when is_binary(r), do: String.downcase(r) == String.downcase(repo)
  defp repo_matches?(_, _), do: false

  defp issue_matches?(nil, _), do: true
  defp issue_matches?(n, issue) when is_integer(n), do: n == issue
  defp issue_matches?(n, issue) when is_binary(n), do: n == to_string(issue)
  defp issue_matches?(_, _), do: false

  defp status(%{"status" => s}) when is_binary(s) do
    if s in Dispatch.callback_statuses(), do: {:ok, s}, else: :invalid
  end

  defp status(_), do: :invalid
end
