defmodule App.MemoryRrfTest do
  use ExUnit.Case, async: true
  alias App.Memory

  test "a doc ranked in both lists outranks a doc ranked in only one" do
    a = [{"turn", 1}, {"turn", 2}]
    b = [{"turn", 2}, {"turn", 3}]
    assert [{"turn", 2} | _] = Memory.rrf_fuse([a, b])
  end

  test "dedups by {source, id} and returns each once" do
    fused = Memory.rrf_fuse([[{"turn", 1}, {"digest", 5}], [{"turn", 1}]])
    assert Enum.count(fused, &(&1 == {"turn", 1})) == 1
    assert {"digest", 5} in fused
  end

  test "empty lists fuse to empty" do
    assert Memory.rrf_fuse([[], []]) == []
  end

  test "single list preserves rank order" do
    assert Memory.rrf_fuse([[{"turn", 9}, {"turn", 8}, {"turn", 7}]]) ==
             [{"turn", 9}, {"turn", 8}, {"turn", 7}]
  end
end
