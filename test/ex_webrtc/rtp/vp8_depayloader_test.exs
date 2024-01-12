defmodule ExWebRTC.RTP.VP8DepayloaderTest do
  use ExUnit.Case, async: true

  alias ExWebRTC.RTP.{VP8Payload, VP8Depayloader}

  test "write/2" do
    depayloader = VP8Depayloader.new()
    # random vp8 data, not necessarily correct
    data = <<0, 1, 2, 3>>

    # packet with entire frame
    vp8_payload = %VP8Payload{n: 0, s: 1, pid: 0, payload: data}
    vp8_payload = VP8Payload.serialize(vp8_payload)

    packet = ExRTP.Packet.new(vp8_payload, marker: true)

    assert {:ok, ^data, %{current_frame: nil, current_timestamp: nil} = depayloader} =
             VP8Depayloader.write(depayloader, packet)

    # packet that doesn't start a new frame
    vp8_payload = %VP8Payload{n: 0, s: 0, pid: 0, payload: data}
    vp8_payload = VP8Payload.serialize(vp8_payload)

    packet = ExRTP.Packet.new(vp8_payload)

    assert {:ok, %{current_frame: nil, current_timestamp: nil} = depayloader} =
             VP8Depayloader.write(depayloader, packet)

    # packet that starts a new frame without finishing the previous one
    vp8_payload = %VP8Payload{n: 0, s: 1, pid: 0, payload: data}
    vp8_payload = VP8Payload.serialize(vp8_payload)

    packet = ExRTP.Packet.new(vp8_payload)

    assert {:ok, %{current_frame: ^data, current_timestamp: 0} = depayloader} =
             VP8Depayloader.write(depayloader, packet)

    data2 = data <> <<0>>
    vp8_payload = %VP8Payload{n: 0, s: 1, pid: 0, payload: data2}
    vp8_payload = VP8Payload.serialize(vp8_payload)

    packet = ExRTP.Packet.new(vp8_payload, timestamp: 3000)

    assert {:ok, %{current_frame: ^data2, current_timestamp: 3000} = depayloader} =
             VP8Depayloader.write(depayloader, packet)

    # packet with timestamp from a new frame that is not a beginning of this frame
    data2 = data
    vp8_payload = %VP8Payload{n: 0, s: 0, pid: 0, payload: data2}
    vp8_payload = VP8Payload.serialize(vp8_payload)

    packet = ExRTP.Packet.new(vp8_payload, timestamp: 6000)

    assert {:ok, %{current_frame: nil, current_timestamp: nil}} =
             VP8Depayloader.write(depayloader, packet)
  end
end
