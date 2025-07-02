defmodule ExWebrtc.RTP.AV1.LEB128Test do
  use ExUnit.Case, async: true

  alias ExWebRTC.RTP.AV1.LEB128

  test "encode" do
    assert <<0>> == LEB128.encode(0)
    assert <<5>> == LEB128.encode(5)
    assert <<0xBF, 0x84, 0x3D>> == LEB128.encode(999_999)
  end

  test "read" do
    assert {:ok, 1, 0} == LEB128.read(<<0>>)
    assert {:ok, 1, 5} == LEB128.read(<<5>>)
    assert {:ok, 3, 999_999} == LEB128.read(<<0xBF, 0x84, 0x3D>>)

    assert {:ok, 3, 999_999} == LEB128.read(<<0xBF, 0x84, 0x3D, 0x00, 0x21, 0x37>>)

    assert {:error, :invalid_leb128_data} == LEB128.read(<<>>)
    assert {:error, :invalid_leb128_data} == LEB128.read(<<255>>)
  end
end
