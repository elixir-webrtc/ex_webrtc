defmodule ExWebRTC.PeerConnection.ConfigurationTest do
  use ExUnit.Case, async: true

  alias ExWebRTC.{PeerConnection, RTPCodecParameters, RTPTransceiver, SessionDescription}

  alias ExSDP.Attribute.Extmap

  @audio_level_rtp_hdr_ext %Extmap{
    id: 1,
    uri: "urn:ietf:params:rtp-hdrext:ssrc-audio-level"
  }

  @mid_rtp_hdr_ext %Extmap{
    id: 4,
    uri: "urn:ietf:params:rtp-hdrext:sdes:mid"
  }

  # some random payload type for the sake of comparison
  @payload_type 100

  @opus_codec %RTPCodecParameters{
    payload_type: @payload_type,
    mime_type: "audio/opus",
    clock_rate: 48_000,
    channels: 2
  }

  @h264_codec %RTPCodecParameters{
    payload_type: @payload_type,
    mime_type: "video/H264",
    clock_rate: 90_000
  }

  @vp8_codec %RTPCodecParameters{
    payload_type: @payload_type,
    mime_type: "video/VP8",
    clock_rate: 90_000
  }

  @av1_codec %RTPCodecParameters{
    payload_type: @payload_type,
    mime_type: "video/AV1",
    clock_rate: 90_000
  }

  @audio_codecs [@opus_codec]
  @video_codecs [@h264_codec, @vp8_codec, @av1_codec]

  test "codecs and rtp hdr extensions" do
    # default audio and video codecs
    # assert there are only them - no g711 or others
    {:ok, pc} = PeerConnection.start_link()

    offer = %SessionDescription{
      type: :offer,
      sdp: File.read!("test/fixtures/sdp/chromium_audio_video_sdp.txt")
    }

    assert :ok = PeerConnection.set_remote_description(pc, offer)
    transceivers = PeerConnection.get_transceivers(pc)

    assert [
             %RTPTransceiver{
               mid: "0",
               direction: :recvonly,
               kind: :audio,
               rtp_hdr_exts: [@mid_rtp_hdr_ext],
               codecs: audio_codecs
             },
             %RTPTransceiver{
               mid: "1",
               direction: :recvonly,
               kind: :video,
               rtp_hdr_exts: [@mid_rtp_hdr_ext],
               codecs: video_codecs
             }
           ] = transceivers

    assert Enum.all?(audio_codecs, fn codec ->
             %{codec | payload_type: @payload_type, sdp_fmtp_line: nil, rtcp_fbs: []} in @audio_codecs
           end)

    assert Enum.all?(video_codecs, fn codec ->
             %{codec | payload_type: @payload_type, sdp_fmtp_line: nil, rtcp_fbs: []} in @video_codecs
           end)

    assert :ok = PeerConnection.close(pc)

    # audio level rtp hdr ext, no audio codecs and one video codec
    # assert there are no audio, h264 and vp8 codecs, and there is audio level
    # rtp hdr extension
    {:ok, pc} =
      PeerConnection.start_link(
        audio_codecs: [],
        video_codecs: [@av1_codec],
        rtp_hdr_extensions: [:audio_level]
      )

    offer = %SessionDescription{
      type: :offer,
      sdp: File.read!("test/fixtures/sdp/chromium_audio_video_sdp.txt")
    }

    assert :ok = PeerConnection.set_remote_description(pc, offer)

    assert [
             %ExWebRTC.RTPTransceiver{
               mid: "0",
               direction: :recvonly,
               kind: :audio,
               rtp_hdr_exts: [@audio_level_rtp_hdr_ext, @mid_rtp_hdr_ext],
               codecs: []
             },
             %RTPTransceiver{
               mid: "1",
               direction: :recvonly,
               kind: :video,
               rtp_hdr_exts: [@mid_rtp_hdr_ext],
               codecs: video_codecs
             }
           ] = PeerConnection.get_transceivers(pc)

    assert Enum.all?(video_codecs, fn codec ->
             %{codec | payload_type: @payload_type, sdp_fmtp_line: nil, rtcp_fbs: []} ==
               @av1_codec
           end)

    {:ok, answer} = PeerConnection.create_answer(pc)
    sdp = ExSDP.parse!(answer.sdp)

    # assert that audio mline has been rejected
    # as we didn't add any supported audio codecs
    assert List.first(sdp.media).port == 0
    assert :ok = PeerConnection.close(pc)

    # additional audio level header extension
    # assert it is only present in audio transceiver
    {:ok, pc} = PeerConnection.start_link(rtp_hdr_extensions: [:audio_level])
    {:ok, tr} = PeerConnection.add_transceiver(pc, :audio)

    tr_rtp_hdr_exts = Enum.map(tr.rtp_hdr_exts, & &1.uri) |> MapSet.new()

    assert MapSet.new([
             "urn:ietf:params:rtp-hdrext:ssrc-audio-level",
             "urn:ietf:params:rtp-hdrext:sdes:mid"
           ]) == tr_rtp_hdr_exts

    {:ok, tr} = PeerConnection.add_transceiver(pc, :video)
    assert [%Extmap{uri: "urn:ietf:params:rtp-hdrext:sdes:mid"}] = tr.rtp_hdr_exts
    :ok = PeerConnection.close(pc)
  end
end
