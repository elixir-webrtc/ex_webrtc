defmodule ExWebRTC.RTPReceiverTest do
  use ExUnit.Case, async: true

  alias ExRTP.Packet
  alias ExWebRTC.{MediaStreamTrack, RTPReceiver}

  test "get_stats/2" do
    timestamp = System.os_time(:millisecond)
    payload = <<1, 2, 3>>

    track = MediaStreamTrack.new(:audio)
    receiver = %RTPReceiver{track: track}

    assert %{
             id: receiver.track.id,
             type: :inbound_rtp,
             timestamp: timestamp,
             ssrc: nil,
             bytes_received: 0,
             packets_received: 0,
             markers_received: 0
           } == RTPReceiver.get_stats(receiver, timestamp)

    packet1 = Packet.new(payload, ssrc: 1234)
    raw_packet1 = Packet.encode(packet1)
    receiver = RTPReceiver.recv(receiver, packet1, raw_packet1)

    assert %{
             id: receiver.track.id,
             type: :inbound_rtp,
             timestamp: timestamp,
             ssrc: 1234,
             bytes_received: byte_size(raw_packet1),
             packets_received: 1,
             markers_received: 0
           } == RTPReceiver.get_stats(receiver, timestamp)

    packet2 = Packet.new(payload, ssrc: 1234, marker: true)
    raw_packet2 = Packet.encode(packet2)
    receiver = RTPReceiver.recv(receiver, packet2, raw_packet2)

    assert %{
             id: receiver.track.id,
             type: :inbound_rtp,
             timestamp: timestamp,
             ssrc: 1234,
             bytes_received: byte_size(raw_packet1) + byte_size(raw_packet2),
             packets_received: 2,
             markers_received: 1
           } == RTPReceiver.get_stats(receiver, timestamp)
  end
end
