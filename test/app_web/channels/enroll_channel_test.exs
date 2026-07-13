defmodule AppWeb.EnrollChannelTest do
  use AppWeb.ChannelCase, async: false

  setup do
    email = "en#{System.unique_integer([:positive])}@t"
    Application.put_env(:app, :allowed_users, [%{email: email, name: "E"}])
    on_exit(fn -> Application.delete_env(:app, :allowed_users) end)

    user = App.Repo.insert!(%App.Users.User{email: email, name: "E"})
    token = AppWeb.UserAuth.socket_token(user.id)
    {:ok, socket} = connect(AppWeb.UserSocket, %{"token" => token})
    %{user: user, socket: socket}
  end

  defp loud_frames(seconds) do
    for _ <- 1..(seconds * 10), do: for(_ <- 1..1_600, into: <<>>, do: <<1000::16-signed-little>>)
  end

  test "streams frames, clip_done persists an enrollment", %{user: u, socket: socket} do
    {:ok, _, socket} = subscribe_and_join(socket, "enroll:#{u.id}", %{})
    for f <- loud_frames(7), do: push(socket, "audio", {:binary, f})
    ref = push(socket, "clip_done", %{"slot" => 1})
    assert_reply ref, :ok, %{slot: 1}
    assert App.Speaker.enrolled_slots(u.id) == [1]
  end

  test "a too-short clip replies error and persists nothing", %{user: u, socket: socket} do
    {:ok, _, socket} = subscribe_and_join(socket, "enroll:#{u.id}", %{})
    for f <- loud_frames(2), do: push(socket, "audio", {:binary, f})
    ref = push(socket, "clip_done", %{"slot" => 1})
    assert_reply ref, :error, %{reason: "too_short"}
    assert App.Speaker.enrolled_slots(u.id) == []
  end

  test "cannot join another user's enroll topic", %{socket: socket} do
    assert {:error, %{reason: "forbidden"}} = subscribe_and_join(socket, "enroll:999999", %{})
  end
end
