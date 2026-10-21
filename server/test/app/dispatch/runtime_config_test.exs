defmodule App.Dispatch.RuntimeConfigTest do
  # Evaluates the real config/runtime.exs with a controlled environment. System env is global,
  # so this can't run alongside other tests.
  use ExUnit.Case, async: false

  @path Path.expand("../../../config/runtime.exs", __DIR__)
  @keys ~w(FORGE_URL FORGE_PUBLIC_URL FORGE_TOKEN CLAUDE_DISPATCH DISPATCH_REPO
           DISPATCH_CALLBACK_SECRET NTFY_URL NTFY_TOPIC NTFY_TOKEN)

  defp runtime(env) do
    saved = Map.new(@keys, &{&1, System.get_env(&1)})

    try do
      Enum.each(@keys, &System.delete_env/1)
      Enum.each(env, fn {k, v} -> System.put_env(k, v) end)
      Config.Reader.read!(@path, env: :test, target: :host)[:app] || []
    after
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end
  end

  describe "the forge" do
    test "links default to the API base when FORGE_PUBLIC_URL is unset" do
      app = runtime(%{"FORGE_URL" => "https://code.test/", "FORGE_TOKEN" => "t"})

      assert %{url: "https://code.test", public_url: "https://code.test"} = app[:forge]
    end

    test "FORGE_PUBLIC_URL is the link base; FORGE_URL stays the API base" do
      app =
        runtime(%{
          "FORGE_URL" => "http://192.168.50.249:3000",
          "FORGE_PUBLIC_URL" => "https://code.clausens.cloud/",
          "FORGE_TOKEN" => "t"
        })

      assert %{url: "http://192.168.50.249:3000", public_url: "https://code.clausens.cloud"} =
               app[:forge]
    end
  end

  describe "ntfy" do
    test "a topic alone is enough: the URL defaults to ntfy.sh" do
      assert %{url: "https://ntfy.sh", topic: "henry", token: nil} =
               runtime(%{"NTFY_TOPIC" => "henry"})[:ntfy]

      assert %{url: "https://ntfy.sh"} =
               runtime(%{"NTFY_TOPIC" => "henry", "NTFY_URL" => ""})[:ntfy]
    end

    test "an own server and token are used as given" do
      assert %{url: "https://ntfy.home.test", topic: "henry", token: "tk"} =
               runtime(%{
                 "NTFY_TOPIC" => "henry",
                 "NTFY_URL" => "https://ntfy.home.test/",
                 "NTFY_TOKEN" => "tk"
               })[:ntfy]
    end

    test "no topic, no ntfy" do
      refute Keyword.has_key?(runtime(%{"NTFY_URL" => "https://ntfy.sh"}), :ntfy)
    end
  end
end
