defmodule ExWebRTC.UtilsTest do
  use ExUnit.Case, async: true

  alias ExWebRTC.Utils

  test "chunk/2" do
    data = <<0, 1, 2, 3, 4, 5, 6, 7>>
    assert [data] == Utils.chunk(data, 100)
    assert [<<0, 1, 2>>, <<3, 4, 5>>, <<6, 7>>] = Utils.chunk(data, 3)
    assert [<<0, 1>>, <<2, 3>>, <<4, 5>>, <<6, 7>>] == Utils.chunk(data, 2)

    assert_raise FunctionClauseError, fn -> Utils.chunk(data, 0) end
    assert_raise FunctionClauseError, fn -> Utils.chunk(data, -22) end

    assert [] == Utils.chunk(<<>>, 100)
  end
end
