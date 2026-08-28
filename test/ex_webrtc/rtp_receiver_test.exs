defmodule ExWebRTC.RTPReceiverTest do
  use ExUnit.Case, async: true

  alias ExRTP.Packet
  alias ExWebRTC.{MediaStreamTrack, RTPReceiver, RTPCodecParameters}

  @codec %RTPCodecParameters{payload_type: 111, mime_type: "audio/opus", clock_rate: 48_000}

  test "get_stats/2" do
    timestamp = System.os_time(:millisecond)
    payload = <<1, 2, 3>>

    track = MediaStreamTrack.new(:audio)
    receiver = RTPReceiver.new(track, [@codec], [], [])

    assert [] == RTPReceiver.get_stats(receiver, timestamp)

    packet1 = Packet.new(payload, ssrc: 1234, payload_type: @codec.payload_type)
    raw_packet1 = Packet.encode(packet1)
    {:ok, _rid, receiver} = RTPReceiver.receive_packet(receiver, packet1, byte_size(raw_packet1))

    assert [
             %{
               id: receiver.track.id,
               track_identifier: receiver.track.id,
               rid: nil,
               type: :inbound_rtp,
               timestamp: timestamp,
               ssrc: 1234,
               bytes_received: byte_size(raw_packet1),
               packets_received: 1,
               markers_received: 0,
               codec: "opus",
               nack_count: 0,
               pli_count: 0,
               packets_lost: 0,
               jitter: +0.0
             }
           ] == RTPReceiver.get_stats(receiver, timestamp)

    packet2 = Packet.new(payload, ssrc: 1234, marker: true, payload_type: @codec.payload_type)
    raw_packet2 = Packet.encode(packet2)
    {:ok, _rid, receiver} = RTPReceiver.receive_packet(receiver, packet2, byte_size(raw_packet2))

    assert [
             %{
               id: receiver.track.id,
               track_identifier: receiver.track.id,
               rid: nil,
               type: :inbound_rtp,
               timestamp: timestamp,
               ssrc: 1234,
               bytes_received: byte_size(raw_packet1) + byte_size(raw_packet2),
               packets_received: 2,
               markers_received: 1,
               codec: "opus",
               nack_count: 0,
               pli_count: 0,
               packets_lost: 0,
               jitter: +0.0
             }
           ] == RTPReceiver.get_stats(receiver, timestamp)

    # packet with unknown payload type
    packet3 = Packet.new(payload, ssrc: 1234, marker: true, payload_type: @codec.payload_type + 1)
    raw_packet3 = Packet.encode(packet3)
    {:error, receiver} = RTPReceiver.receive_packet(receiver, packet3, byte_size(raw_packet3))

    # even though, stats should be updated
    assert [
             %{
               id: receiver.track.id,
               track_identifier: receiver.track.id,
               rid: nil,
               type: :inbound_rtp,
               timestamp: timestamp,
               ssrc: 1234,
               bytes_received:
                 byte_size(raw_packet1) + byte_size(raw_packet2) + byte_size(raw_packet3),
               packets_received: 3,
               markers_received: 2,
               codec: "opus",
               nack_count: 0,
               pli_count: 0,
               packets_lost: 0,
               jitter: +0.0
             }
           ] == RTPReceiver.get_stats(receiver, timestamp)
  end

  test "get_stats/2 reports packets lost" do
    track = MediaStreamTrack.new(:audio)
    receiver = RTPReceiver.new(track, [@codec], [], [:rtcp_reports])

    # sequence numbers 1, 2 and 5 -> packets 3 and 4 are missing
    receiver =
      Enum.reduce([1, 2, 5], receiver, fn seq_no, receiver ->
        packet =
          Packet.new(<<1, 2, 3>>,
            ssrc: 1234,
            sequence_number: seq_no,
            payload_type: @codec.payload_type
          )

        {:ok, _rid, receiver} =
          RTPReceiver.receive_packet(receiver, packet, byte_size(Packet.encode(packet)))

        receiver
      end)

    assert [%{packets_lost: 2, packets_received: 3}] =
             RTPReceiver.get_stats(receiver, System.os_time(:millisecond))
  end
end
