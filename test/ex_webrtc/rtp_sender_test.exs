defmodule ExWebRTC.RTPSenderTest do
  use ExUnit.Case, async: true

  alias ExRTP.Packet.Extension.SourceDescription
  alias ExSDP.Attribute.Extmap

  alias ExWebRTC.{MediaStreamTrack, RTPCodecParameters, RTPSender}

  @ssrc 354_947
  @rtx_ssrc 123_455

  @rtp_hdr_exts [%Extmap{id: 1, uri: "urn:ietf:params:rtp-hdrext:sdes:mid"}]

  @vp8 %RTPCodecParameters{
    payload_type: 96,
    mime_type: "video/VP8",
    clock_rate: 90_000
  }

  @av1 %RTPCodecParameters{
    payload_type: 45,
    mime_type: "video/AV1",
    clock_rate: 90_000,
    sdp_fmtp_line: %ExSDP.Attribute.FMTP{pt: 45, level_idx: 5, profile: 0, tier: 0}
  }

  @av1_45khz %RTPCodecParameters{
    payload_type: 46,
    mime_type: "video/AV1",
    clock_rate: 45_000,
    sdp_fmtp_line: %ExSDP.Attribute.FMTP{pt: 46, level_idx: 5, profile: 0, tier: 0}
  }

  @rtx %ExWebRTC.RTPCodecParameters{
    payload_type: 124,
    mime_type: "video/rtx",
    clock_rate: 90_000,
    sdp_fmtp_line: %ExSDP.Attribute.FMTP{
      pt: 124,
      apt: 96
    }
  }

  test "new/7" do
    track = MediaStreamTrack.new(:video)

    sender = RTPSender.new(track, @ssrc, @rtx_ssrc, [])

    assert sender.track == track
    assert sender.codec == nil
    assert sender.rtx_codec == nil
    assert sender.codecs == []
    assert sender.rtp_hdr_exts == %{}
  end

  test "set_codecs/2" do
    sender = RTPSender.new(nil, @ssrc, @rtx_ssrc, [])

    # Before codecs are negotaited (i.e. update is called),
    # sender's state should be clean, and setting codecs shouldn't be possible.
    assert sender.codec == nil
    assert sender.rtx_codec == nil
    assert sender.codecs == []
    assert sender.rtp_hdr_exts == %{}
    assert {:error, :invalid_codec} = RTPSender.set_codec(sender, @av1)

    sender = RTPSender.update(sender, "1", [@vp8, @av1, @av1_45khz, @rtx], @rtp_hdr_exts)
    assert sender.codec == @vp8

    assert {:ok, %{codec: @av1} = sender} = RTPSender.set_codec(sender, @av1)

    assert {:error, :invalid_codec} =
             RTPSender.set_codec(sender, %{@av1 | payload_type: @av1.payload_type + 1})

    # rtx codec shouldn't be accepted
    assert {:error, :invalid_codec} = RTPSender.set_codec(sender, @rtx)

    # codec with different clock rate should be accepted
    assert {:ok, %{codec: @av1_45khz} = sender} = RTPSender.set_codec(sender, @av1_45khz)

    # once we send an RTP packet, codec with different clock rate shouldn't be accepted
    {_packet, sender} = RTPSender.send_packet(sender, ExRTP.Packet.new(<<>>), false)
    assert {:error, :invalid_codec} = RTPSender.set_codec(sender, @av1)
  end

  test "update/4" do
    track = MediaStreamTrack.new(:video)
    sender = RTPSender.new(track, @ssrc, @rtx_ssrc, [])

    assert %{codec: @vp8, rtx_codec: @rtx, codecs: [@vp8, @av1, @rtx]} =
             sender =
             RTPSender.update(sender, "1", [@vp8, @av1, @rtx], @rtp_hdr_exts)

    assert %{codec: @vp8, rtx_codec: nil} =
             sender =
             RTPSender.update(sender, "1", [@vp8, @av1], @rtp_hdr_exts)

    assert %{codec: nil, rtx_codec: nil} =
             sender = RTPSender.update(sender, "1", [@av1], @rtp_hdr_exts)

    # once codec is cleared, another update shouldn't set it (until set_codec clears selected codec)
    assert %{codec: nil, rtx_codec: nil} = RTPSender.update(sender, "1", [@av1], @rtp_hdr_exts)
  end

  describe "send_packet/3" do
    setup do
      track = MediaStreamTrack.new(:video)
      sender = RTPSender.new(track, @ssrc, @rtx_ssrc, [])
      %{sender: sender}
    end

    test "when there is no codec", %{sender: sender} do
      sender = RTPSender.update(sender, "1", [], @rtp_hdr_exts)
      assert {<<>>, ^sender} = RTPSender.send_packet(sender, ExRTP.Packet.new(<<>>), false)
    end

    test "when there is no rtx codec", %{sender: sender} do
      sender = RTPSender.update(sender, "1", [], @rtp_hdr_exts)
      assert {<<>>, ^sender} = RTPSender.send_packet(sender, ExRTP.Packet.new(<<>>), true)
    end

    test "when there is codec", %{sender: sender} do
      sender = RTPSender.update(sender, "1", [@vp8], @rtp_hdr_exts)

      packet = ExRTP.Packet.new(<<>>)

      {packet, sender} = RTPSender.send_packet(sender, packet, false)

      {:ok, packet} = ExRTP.Packet.decode(packet)

      assert packet.ssrc == @ssrc
      assert packet.marker == false
      assert packet.payload_type == 96
      # timestamp and sequence number shouldn't be overwritten
      assert packet.timestamp == 0
      assert packet.sequence_number == 0
      # there should only be one extension
      assert [ext] = packet.extensions
      assert {:ok, %{text: "1"}} = SourceDescription.from_raw(ext)

      # check sequence number rollover and marker flag
      packet = ExRTP.Packet.new(<<>>, sequence_number: 1, marker: true)
      {packet, _sender} = RTPSender.send_packet(sender, packet, false)
      {:ok, packet} = ExRTP.Packet.decode(packet)
      assert packet.sequence_number == 1
      # marker flag shouldn't be overwritten
      assert packet.marker == true

      # assert report recorder was initialized
      assert sender.report_recorder.clock_rate == sender.codec.clock_rate
      assert sender.report_recorder.sender_ssrc == sender.ssrc
    end
  end

  test "get_stats/2" do
    track = MediaStreamTrack.new(:video)
    sender = RTPSender.new(track, @ssrc, @rtx_ssrc, [])

    timestamp = System.os_time(:millisecond)
    payload = <<1, 2, 3>>

    assert %{
             timestamp: timestamp,
             type: :outbound_rtp,
             id: sender.id,
             track_identifier: sender.track.id,
             ssrc: sender.ssrc,
             packets_sent: 0,
             bytes_sent: 0,
             markers_sent: 0,
             nack_count: 0,
             pli_count: 0,
             retransmitted_packets_sent: 0,
             retransmitted_bytes_sent: 0
           } == RTPSender.get_stats(sender, timestamp)

    sender = RTPSender.update(sender, "1", [@vp8, @rtx], @rtp_hdr_exts)

    packet = ExRTP.Packet.new(payload)
    {data1, sender} = RTPSender.send_packet(sender, packet, false)

    assert %{
             timestamp: timestamp,
             type: :outbound_rtp,
             id: sender.id,
             track_identifier: sender.track.id,
             ssrc: sender.ssrc,
             packets_sent: 1,
             bytes_sent: byte_size(data1),
             markers_sent: 0,
             nack_count: 0,
             pli_count: 0,
             retransmitted_packets_sent: 0,
             retransmitted_bytes_sent: 0
           } == RTPSender.get_stats(sender, timestamp)

    packet = ExRTP.Packet.new(payload, marker: true)
    {data2, sender} = RTPSender.send_packet(sender, packet, false)

    assert %{
             timestamp: timestamp,
             type: :outbound_rtp,
             id: sender.id,
             track_identifier: sender.track.id,
             ssrc: sender.ssrc,
             packets_sent: 2,
             bytes_sent: byte_size(data1) + byte_size(data2),
             markers_sent: 1,
             nack_count: 0,
             pli_count: 0,
             retransmitted_packets_sent: 0,
             retransmitted_bytes_sent: 0
           } == RTPSender.get_stats(sender, timestamp)
  end
end
