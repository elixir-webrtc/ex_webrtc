defmodule ExWebRTC.RTPSenderTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias ExRTP.Packet.Extension.SourceDescription
  alias ExSDP.Attribute.{Extmap, FMTP}

  alias ExWebRTC.{MediaStreamTrack, RTPCodecParameters, RTPSender}

  @max_seq_num (1 <<< 32) - 1
  @ssrc 354_947

  test "send/2" do
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
end
