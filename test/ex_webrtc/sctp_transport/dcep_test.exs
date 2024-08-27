defmodule ExWebRTC.SCTPTransport.DCEPTest do
  use ExUnit.Case, async: true

  alias ExWebRTC.SCTPTransport.DCEP

  @encoded_dco <<3, 130, 0, 5, 0, 0, 0, 100, 0, 5, 0, 6, 104, 101, 108, 108, 111, 119, 101, 98,
                 114, 116, 99>>
  @decoded_dco %DCEP.DataChannelOpen{
    reliability: :timed,
    order: :unordered,
    label: "hello",
    protocol: "webrtc",
    priority: 5,
    param: 100
  }

  @encoded_dca <<2>>
  @decoded_dca %DCEP.DataChannelAck{}

  describe "decode/1" do
    test "DataChannelAck" do
      assert DCEP.encode(@decoded_dca) == @encoded_dca
    end

    test "DataChannelOpen" do
      assert DCEP.encode(@decoded_dco) == @encoded_dco
    end
  end

  describe "encode/1" do
    test "DataChannelAck" do
      assert {:ok, @decoded_dca} = DCEP.decode(@encoded_dca)
    end

    test "DataChannelOpen" do
      assert {:ok, @decoded_dco} = DCEP.decode(@encoded_dco)
    end
  end
end
