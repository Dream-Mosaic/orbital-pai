defmodule App.Adapters.Embeddings.VoyageTest do
  use ExUnit.Case, async: false
  alias App.Adapters.Embeddings.Voyage

  setup do
    Application.put_env(:app, :voyage_req_opts, plug: {Req.Test, __MODULE__})
    Application.put_env(:app, :voyage_api_key, "test-key")

    on_exit(fn ->
      Application.delete_env(:app, :voyage_req_opts)
      Application.delete_env(:app, :voyage_api_key)
    end)

    :ok
  end

  test "posts model/input_type/output_dimension and returns vectors in input order" do
    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)
      assert decoded["model"] == "voyage-4-lite"
      assert decoded["input_type"] == "document"
      assert decoded["output_dimension"] == 1024
      assert decoded["input"] == ["a", "b"]
      assert ["Bearer test-key"] = Plug.Conn.get_req_header(conn, "authorization")

      Req.Test.json(conn, %{
        "data" => [
          %{"embedding" => [0.1, 0.2], "index" => 0},
          %{"embedding" => [0.3, 0.4], "index" => 1}
        ]
      })
    end)

    assert {:ok, [[0.1, 0.2], [0.3, 0.4]]} = Voyage.embed(["a", "b"], :document)
  end

  test "reorders by index so output matches input order" do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        "data" => [%{"embedding" => [9.0], "index" => 1}, %{"embedding" => [8.0], "index" => 0}]
      })
    end)

    assert {:ok, [[8.0], [9.0]]} = Voyage.embed(["x", "y"], :document)
  end

  test "maps a non-200 to {:error, _} (degradation)" do
    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 429, "slow down") end)
    assert {:error, _} = Voyage.embed(["a"], :query)
  end

  test "empty input short-circuits" do
    assert {:ok, []} = Voyage.embed([], :document)
  end
end
