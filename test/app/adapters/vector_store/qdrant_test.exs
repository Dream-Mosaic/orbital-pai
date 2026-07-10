defmodule App.Adapters.VectorStore.QdrantTest do
  use ExUnit.Case, async: false
  alias App.Adapters.VectorStore.Qdrant

  describe "point_id/2" do
    test "is a valid v5 UUID and deterministic per (source, id)" do
      id = Qdrant.point_id("turn", 123)
      assert id == Qdrant.point_id("turn", 123)
      assert id =~ ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
    end

    test "differs across sources and ids" do
      refute Qdrant.point_id("turn", 1) == Qdrant.point_id("digest", 1)
      refute Qdrant.point_id("turn", 1) == Qdrant.point_id("turn", 2)
    end
  end

  describe "search/3 REST shape" do
    setup do
      Application.put_env(:app, :qdrant_req_opts, plug: {Req.Test, __MODULE__})
      Application.put_env(:app, :qdrant_url, "http://qdrant.test:6333")

      on_exit(fn ->
        Application.delete_env(:app, :qdrant_req_opts)
        Application.delete_env(:app, :qdrant_url)
      end)

      :ok
    end

    test "filters by user_id and maps payload to {source, id}" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert get_in(decoded, ["filter", "must"]) == [
                 %{"key" => "user_id", "match" => %{"value" => 7}}
               ]

        assert decoded["with_payload"] == true

        Req.Test.json(conn, %{
          "result" => %{
            "points" => [
              %{"id" => "u1", "payload" => %{"source" => "digest", "source_id" => 42}},
              %{"id" => "u2", "payload" => %{"source" => "turn", "source_id" => 9}}
            ]
          }
        })
      end)

      assert {:ok, [%{source: "digest", id: 42}, %{source: "turn", id: 9}]} =
               Qdrant.search([0.1, 0.2], 7, 20)
    end

    test "non-200 → {:error, _}" do
      Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end)
      assert {:error, _} = Qdrant.search([0.1], 7, 20)
    end
  end
end
