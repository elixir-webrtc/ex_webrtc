defmodule ExWebRTC.RTP.DTMF.DepayloaderTest do
  use ExUnit.Case, async: true

  alias ExWebRTC.RTP.Depayloader
  alias ExRTP.Packet

  test "does not return multiple events when timestamp does not change" do
    depayloader = Depayloader.DTMF.new()

    # Marker denotes beginning of a new event.
    # The last packet is transmitted 3 times.
    ev = <<0::8, 1::1, 0::1, 0::6, 8000::16>>
    packet1 = Packet.new(ev, marker: true, sequence_number: 1234, timestamp: 1234)
    packet2 = Packet.new(ev, marker: true, sequence_number: 1235, timestamp: 1234)
    packet3 = Packet.new(ev, marker: true, sequence_number: 1236, timestamp: 1234)

    assert {%{event: "0", code: 0}, depayloader} =
             Depayloader.DTMF.depayload(depayloader, packet1)

    assert {nil, depayloader} = Depayloader.DTMF.depayload(depayloader, packet2)
    assert {nil, _depayloader} = Depayloader.DTMF.depayload(depayloader, packet3)
  end

  test "does not return multiple events when the event is split across multiple RTP packets" do
    depayloader = Depayloader.DTMF.new()

    packet1 =
      Packet.new(<<0::8, 0::1, 0::1, 0::6, 0xFF::16>>,
        marker: true,
        sequence_number: 1234,
        timestamp: 1234
      )

    assert {%{event: "0", code: 0}, depayloader} =
             Depayloader.DTMF.depayload(depayloader, packet1)

    packet2 =
      Packet.new(<<0::8, 1::1, 0::1, 0::6, 8000::16>>,
        marker: false,
        sequence_number: 1235,
        timestamp: 1234 + 0xFF
      )

    assert {nil, _depayloader} = Depayloader.DTMF.depayload(depayloader, packet2)
  end

  test "ignores invalid packets" do
    depayloader = Depayloader.DTMF.new()

    ev = <<>>
    packet = Packet.new(ev, marker: true)
    assert {nil, depayloader} = Depayloader.DTMF.depayload(depayloader, packet)

    ev = <<1, 2, 3, 4, 5>>
    packet = Packet.new(ev, marker: true)
    assert {nil, _depayloader} = Depayloader.DTMF.depayload(depayloader, packet)
  end
end
