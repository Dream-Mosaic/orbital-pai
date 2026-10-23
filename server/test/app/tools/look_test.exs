defmodule App.Tools.LookTest do
  # async: false — a session-bound Conversation runs DB pulls right after init (shared
  # sandbox), the text model is a global Mox mock, and one test changes the camera wait.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Mox

  alias App.Conversations.Conversation
  alias App.Tools.Look

  setup :set_mox_global
  setup :verify_on_exit!

  @jpeg <<0xFF, 0xD8, 0xFF, 0xE0>> <> :binary.copy(<<7>>, 4_000)

  setup do
    App.DataCase.setup_sandbox(%{async: false})
    sid = "look-#{System.unique_integer([:positive])}"
    %{sid: sid, ctx: %{session_id: sid, user_id: nil, config: %App.Config{}}}
  end

  defp start_session(sid, client) do
    {:ok, pid} =
      Conversation.start_link(
        client: client,
        config: %App.Config{},
        session_id: sid,
        name: {:via, Registry, {App.Conversations.Registry, sid}}
      )

    on_exit(fn -> stop_session(pid) end)
    pid
  end

  # Synchronous, so the init pulls can't outlive the sandbox owner (see conversation_test.exs).
  # It is linked to the test process, so it may already be stopping by the time this runs.
  defp stop_session(pid) do
    if Process.alive?(pid) do
      App.DataCase.drain_conversation_tasks()
      :gen_statem.stop(pid, :normal, 2_000)
    end
  catch
    :exit, _ -> :ok
  end

  # The bound device: answers every capture with `reply` (or never, for :silent) and tells
  # the test about each push it gets.
  defp device(reply) do
    test = self()

    spawn_link(fn ->
      Stream.repeatedly(fn ->
        receive do
          {:to_client, {:camera_capture, id, facing}} ->
            send(test, {:asked, id, facing})
            if reply != :silent, do: App.Camera.deliver(id, reply)

          {:to_client, {:camera_done, id}} ->
            send(test, {:done, id})

          _other ->
            :ok
        end
      end)
      |> Stream.run()
    end)
  end

  defp look(ctx, question \\ "what am I holding?"),
    do: Look.execute("look", %{"question" => question}, ctx)

  describe "declarations and prompt" do
    test "one function, look(question), with question required" do
      assert [%{name: "look", parameters: params}] = Look.declarations()
      assert params.required == ["question"]
      assert params.properties.question.type == "string"
    end

    test "the prompt says when to use it and never to guess" do
      prompt = Look.prompt()
      assert prompt =~ "look"
      for verb <- ~w(see read identify count describe), do: assert(prompt =~ verb)
      assert prompt =~ ~r/never guess/i
    end

    test "25 s cap, a short bridge, never cached" do
      assert Look.timeout("look") == 25_000
      assert [_ | _] = Look.bridge("look")
      refute function_exported?(Look, :cache_ttl, 1)
    end

    test "is always on (in the default tools) and advertised in the brain prompt" do
      assert App.Tools.Look in App.Config.default().tools
      assert App.Tools.prompt_block(App.Config.default()) =~ Look.prompt()
    end

    test "counts as a read: a carried-forward request may look again" do
      assert App.Tools.read_only?("look")
    end
  end

  test "captures, asks the vision model about the photo, and returns what it saw", %{
    sid: sid,
    ctx: ctx
  } do
    dev = device({:ok, @jpeg})
    start_session(sid, dev)

    expect(App.TextModelMock, :describe_image, fn jpeg, question, opts ->
      assert jpeg == @jpeg
      assert question == "what am I holding?"
      assert %App.Config{} = opts[:config]
      {:ok, "A red coffee mug."}
    end)

    assert {:ok, %{seen: "A red coffee mug.", capture_id: id}} = look(ctx)
    assert_received {:asked, ^id, "back"}
    # the device is told to release the frozen snapshot once the answer is in
    assert_receive {:done, ^id}, 500
  end

  test "logs one [look] line with sizes and timings, never the image", %{sid: sid, ctx: ctx} do
    level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: level) end)

    start_session(sid, device({:ok, @jpeg}))
    stub(App.TextModelMock, :describe_image, fn _j, _q, _o -> {:ok, "A mug."} end)

    log = capture_log([level: :info], fn -> look(ctx) end)

    assert [line] = Regex.scan(~r/\[look\][^\n]*/, log) |> List.flatten()
    assert line =~ "captured 4 KB"
    assert line =~ "vision"
    refute log =~ Base.encode64(@jpeg)
    refute log =~ "A mug."
  end

  test "no live conversation: I can't see from this device", %{ctx: ctx} do
    assert {:error, "I can't see from this device."} = look(ctx)
    assert {:error, "I can't see from this device."} = look(%{ctx | session_id: nil})
  end

  test "a device with no camera, or no permission: I can't see from this device", %{
    sid: sid,
    ctx: ctx
  } do
    start_session(sid, device({:error, {:device, "no_camera"}}))
    assert {:error, "I can't see from this device."} = look(ctx)
  end

  test "a denied camera is the same answer", %{sid: sid, ctx: ctx} do
    start_session(sid, device({:error, {:device, "denied"}}))
    assert {:error, "I can't see from this device."} = look(ctx)
  end

  test "a device that never answers: The camera didn't answer.", %{sid: sid, ctx: ctx} do
    Application.put_env(:app, :camera_wait_ms, 50)
    on_exit(fn -> Application.delete_env(:app, :camera_wait_ms) end)
    start_session(sid, device(:silent))

    assert {:error, "The camera didn't answer."} = look(ctx)
  end

  test "a camera that failed to shoot: The camera didn't answer.", %{sid: sid, ctx: ctx} do
    start_session(sid, device({:error, {:device, "failed"}}))
    assert {:error, "The camera didn't answer."} = look(ctx)
  end

  test "an unusable frame: I couldn't make anything out.", %{sid: sid, ctx: ctx} do
    start_session(sid, device({:error, :bad_frame}))
    assert {:error, "I couldn't make anything out."} = look(ctx)
  end

  test "a failed vision call: I couldn't make anything out. (and the device lets go)", %{
    sid: sid,
    ctx: ctx
  } do
    start_session(sid, device({:ok, @jpeg}))
    expect(App.TextModelMock, :describe_image, fn _j, _q, _o -> {:error, {:http, 500}} end)

    assert {:error, "I couldn't make anything out."} = look(ctx)
    assert_receive {:done, _id}, 500
  end

  test "a missing or blank question still looks, asking what it is", %{sid: sid, ctx: ctx} do
    start_session(sid, device({:ok, @jpeg}))

    expect(App.TextModelMock, :describe_image, 2, fn _j, question, _o ->
      assert question =~ ~r/what is this/i
      {:ok, "A mug."}
    end)

    assert {:ok, _} = Look.execute("look", %{}, ctx)
    assert {:ok, _} = look(ctx, "   ")
  end

  test "works through the registry: a typed turn's tool call captures on the bound device", %{
    sid: sid,
    ctx: ctx
  } do
    start_session(sid, device({:ok, @jpeg}))
    stub(App.TextModelMock, :describe_image, fn _j, _q, _o -> {:ok, "Three fingers."} end)

    assert {:ok, %{seen: "Three fingers.", capture_id: _}} =
             App.Tools.execute("look", %{"question" => "how many fingers?"}, ctx)
  end
end
