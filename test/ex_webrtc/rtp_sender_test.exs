defmodule ExWebRTC.RTPSenderTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias ExRTP.Packet.Extension.SourceDescription
  alias ExSDP.Attribute.{Extmap, FMTP}

  alias ExWebRTC.{MediaStreamTrack, RTPCodecParameters, RTPSender}

  @max_seq_num (1 <<< 32) - 1
  @ssrc 354_947

  setup do
    track = MediaStreamTrack.new(:audio)

    codec = %RTPCodecParameters{
      payload_type: 111,
      mime_type: "audio/opus",
      clock_rate: 48_000,
      channels: 2,
      sdp_fmtp_line: %FMTP{pt: 111, minptime: 10, useinbandfec: true}
    }

    rtp_hdr_exts = [%Extmap{id: 1, uri: "urn:ietf:params:rtp-hdrext:sdes:mid"}]

    sender = RTPSender.new(track, codec, rtp_hdr_exts, "1", @ssrc)

    %{sender: sender}
  end

  test "send/2", %{sender: sender} do
    sender = %RTPSender{sender | last_seq_num: 10_000}

    packet = ExRTP.Packet.new(<<>>)

    {packet, sender} = RTPSender.send(sender, packet)

    {:ok, packet} = ExRTP.Packet.decode(packet)

    assert packet.ssrc == @ssrc
    assert packet.marker == false
    assert packet.payload_type == 111
    assert packet.sequence_number == 10_001
    # timestamp shouldn't be overwritten
    assert packet.timestamp == 0
    # there should only be one extension
    assert [ext] = packet.extensions
    assert {:ok, %{text: "1"}} = SourceDescription.from_raw(ext)

    # check sequence number rollover and marker flag
    sender = %RTPSender{sender | last_seq_num: @max_seq_num}
    packet = ExRTP.Packet.new(<<>>, sequence_number: 1, marker: true)
    {packet, _sender} = RTPSender.send(sender, packet)
    {:ok, packet} = ExRTP.Packet.decode(packet)
    assert packet.sequence_number == 0
    # marker flag shouldn't be overwritten
    assert packet.marker == true
  end

  test "get_stats/2", %{sender: sender} do
    timestamp = System.os_time(:millisecond)
    payload = <<1, 2, 3>>

    assert %{
             timestamp: timestamp,
             type: :outbound_rtp,
             id: sender.id,
             ssrc: sender.ssrc,
             packets_sent: 0,
             bytes_sent: 0,
             markers_sent: 0
           } == RTPSender.get_stats(sender, timestamp)

    packet = ExRTP.Packet.new(payload)
    {data1, sender} = RTPSender.send(sender, packet)

    assert %{
             timestamp: timestamp,
             type: :outbound_rtp,
             id: sender.id,
             ssrc: sender.ssrc,
             packets_sent: 1,
             bytes_sent: byte_size(data1),
             markers_sent: 0
           } == RTPSender.get_stats(sender, timestamp)

    packet = ExRTP.Packet.new(payload, marker: true)
    {data2, sender} = RTPSender.send(sender, packet)

    assert %{
             timestamp: timestamp,
             type: :outbound_rtp,
             id: sender.id,
             ssrc: sender.ssrc,
             packets_sent: 2,
             bytes_sent: byte_size(data1) + byte_size(data2),
             markers_sent: 1
           } == RTPSender.get_stats(sender, timestamp)
  end
end
