defmodule ExWebRTC.RTPReceiverTest do
  use ExUnit.Case, async: true

  alias ExRTP.Packet
  alias ExWebRTC.{MediaStreamTrack, RTPReceiver, RTPCodecParameters}

  @codec %RTPCodecParameters{payload_type: 111, mime_type: "audio/opus", clock_rate: 48_000}

  test "get_stats/2" do
    timestamp = System.os_time(:millisecond)
    payload = <<1, 2, 3>>

    track = MediaStreamTrack.new(:audio)
    receiver = RTPReceiver.new(track, @codec, [], [])

    assert [] == RTPReceiver.get_stats(receiver, timestamp)

    packet1 = Packet.new(payload, ssrc: 1234)
    raw_packet1 = Packet.encode(packet1)
    {_rid, receiver} = RTPReceiver.receive_packet(receiver, packet1, byte_size(raw_packet1))

    assert [
             %{
               id: receiver.track.id,
               rid: nil,
               type: :inbound_rtp,
               timestamp: timestamp,
               ssrc: 1234,
               bytes_received: byte_size(raw_packet1),
               packets_received: 1,
               markers_received: 0,
               codec: "opus",
               nack_count: 0,
               pli_count: 0
             }
           ] == RTPReceiver.get_stats(receiver, timestamp)

    packet2 = Packet.new(payload, ssrc: 1234, marker: true)
    raw_packet2 = Packet.encode(packet2)
    {_rid, receiver} = RTPReceiver.receive_packet(receiver, packet2, byte_size(raw_packet2))

    assert [
             %{
               id: receiver.track.id,
               rid: nil,
               type: :inbound_rtp,
               timestamp: timestamp,
               ssrc: 1234,
               bytes_received: byte_size(raw_packet1) + byte_size(raw_packet2),
               packets_received: 2,
               markers_received: 1,
               codec: "opus",
               nack_count: 0,
               pli_count: 0
             }
           ] == RTPReceiver.get_stats(receiver, timestamp)
  end
end
