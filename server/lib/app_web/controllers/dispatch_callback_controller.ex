defmodule AppWeb.DispatchCallbackController do
  @moduledoc "HMAC-signed status callback from the claude-dispatch workflow. Never logs body/signature."
  use AppWeb, :controller
  require Logger

  alias App.Dispatch

  def create(conn, params) do
    with :ok <- verify(conn),
         {:ok, job} <- find_job(params),
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

  defp find_job(%{"job_id" => id}) do
    with {int, ""} <- Integer.parse(to_string(id)),
         %Dispatch.Job{} = job <- Dispatch.get_job(int) do
      {:ok, job}
    else
      _ -> {:reject, "unknown job"}
    end
  end

  defp find_job(_), do: :invalid

  defp status(%{"status" => s}) when is_binary(s) do
    if s in Dispatch.callback_statuses(), do: {:ok, s}, else: :invalid
  end

  defp status(_), do: :invalid
end
