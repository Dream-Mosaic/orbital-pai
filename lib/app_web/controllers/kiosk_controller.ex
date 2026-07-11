defmodule AppWeb.KioskController do
  use AppWeb, :controller

  # Trusted-device user switch (wall tablet). Config-gated OFF by default (App.Config
  # :kiosk_user_switch); requires an ALREADY-authenticated session (enforced by the router's
  # auth pipeline — an unauthenticated POST never reaches this action); the target user must
  # exist AND still be allowlisted. Reuses UserAuth.log_in_user/2 (renew_session + put_session)
  # so the resulting session is IDENTICAL in shape to a normal login — no parallel mechanism, no
  # session fixation. Threat model: physical access to the unlocked wall == household trust (same
  # class as a shared smart speaker) — this endpoint's job is gate correctness, not that risk.
  #
  # The `with` chain fails CLOSED on every step: gate off → false doesn't match `true` → 403;
  # a non-numeric/garbage/missing `user_id` → `to_int/1` returns nil, which doesn't match the
  # `is_integer` guard below (so `App.Users.get/1` is NEVER called with nil — it raises on a nil
  # id) → 403; a well-formed but nonexistent id → `App.Users.get/1` returns nil → doesn't match
  # `%App.Users.User{}` → 403; a real but non-allowlisted target → `true <- false` → 403.
  def switch_user(conn, %{"user_id" => id}) do
    with true <- App.Config.default().kiosk_user_switch,
         int_id when is_integer(int_id) <- to_int(id),
         %App.Users.User{} = user <- App.Users.get(int_id),
         true <- App.Users.allowed?(user.email) do
      conn
      |> AppWeb.UserAuth.log_in_user(user)
      |> redirect(to: "/?kiosk=1")
    else
      _ -> conn |> send_resp(403, "forbidden") |> halt()
    end
  end

  def switch_user(conn, _params), do: conn |> send_resp(403, "forbidden") |> halt()

  defp to_int(id) when is_integer(id), do: id

  defp to_int(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp to_int(_), do: nil
end
