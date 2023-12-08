defmodule ExWebrtc.RTP.LEB128Test do
  use ExUnit.Case, async: true

  alias ExWebRTC.RTP.LEB128

  test "encode" do
    assert <<0>> == LEB128.encode(0)
    assert <<5>> == LEB128.encode(5)
    assert <<0xBF, 0x84, 0x3D>> == LEB128.encode(999_999)
  end

  test "read" do
    assert {1, 0} == LEB128.read(<<0>>)
    assert {1, 5} == LEB128.read(<<5>>)
    assert {3, 999_999} == LEB128.read(<<0xBF, 0x84, 0x3D>>)
  end
end
