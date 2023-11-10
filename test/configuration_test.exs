defmodule ExWebRTC.PeerConnection.ConfigurationTest do
  use ExUnit.Case

  alias ExWebRTC.{PeerConnection, RTPCodecParameters, RTPTransceiver, SessionDescription}

  alias ExSDP.Attribute.{Extmap, FMTP}

  test "codecs and rtp hdr extensions" do
    audio_level_rtp_hdr_ext = %Extmap{
      id: 1,
      uri: "urn:ietf:params:rtp-hdrext:ssrc-audio-level"
    }

    mid_rtp_hdr_ext = %Extmap{
      id: 4,
      uri: "urn:ietf:params:rtp-hdrext:sdes:mid"
    }

    opus_codec = %RTPCodecParameters{
      payload_type: 111,
      mime_type: "audio/opus",
      clock_rate: 48_000,
      channels: 2,
      sdp_fmtp_line: %FMTP{
        pt: 111,
        minptime: 10,
        useinbandfec: true
      },
      rtcp_fbs: []
    }

    h264_codec = %RTPCodecParameters{
      payload_type: 102,
      mime_type: "video/H264",
      clock_rate: 90_000,
      sdp_fmtp_line: %FMTP{
        pt: 102,
        profile_level_id: 0x42001F,
        level_asymmetry_allowed: true,
        packetization_mode: 1
      },
      rtcp_fbs: []
    }

    vp8_codec = %RTPCodecParameters{
      payload_type: 96,
      mime_type: "video/VP8",
      clock_rate: 90_000,
      rtcp_fbs: []
    }

    av1_codec = %RTPCodecParameters{
      payload_type: 45,
      mime_type: "video/AV1",
      clock_rate: 90_000,
      rtcp_fbs: []
    }

    # default audio and video codecs
    # assert there are only them - no av1, g711 or others
    {:ok, pc} = PeerConnection.start_link()

    offer = %SessionDescription{
      type: :offer,
      sdp: File.read!("test/fixtures/audio_video_sdp.txt")
    }

    assert :ok = PeerConnection.set_remote_description(pc, offer)
    transceivers = PeerConnection.get_transceivers(pc)

    assert [
             %RTPTransceiver{
               mid: "0",
               direction: :recvonly,
               kind: :audio,
               rtp_hdr_exts: [^mid_rtp_hdr_ext],
               codecs: [^opus_codec]
             },
             %RTPTransceiver{
               mid: "1",
               direction: :recvonly,
               kind: :video,
               rtp_hdr_exts: [^mid_rtp_hdr_ext],
               codecs: [^vp8_codec, ^h264_codec]
             }
           ] = transceivers

    assert :ok = PeerConnection.close(pc)

    # audio level rtp hdr ext, no audio codecs and one non-default av1 codec
    # assert there are no audio, h264 and vp8 codecs, and there is audio level
    # rtp hdr extension
    {:ok, pc} =
      PeerConnection.start_link(
        audio_codecs: [],
        video_codecs: [av1_codec],
        rtp_hdr_extensions: [:audio_level]
      )

    offer = %SessionDescription{
      type: :offer,
      sdp: File.read!("test/fixtures/audio_video_sdp.txt")
    }

    assert :ok = PeerConnection.set_remote_description(pc, offer)

    assert [
             %ExWebRTC.RTPTransceiver{
               mid: "0",
               direction: :recvonly,
               kind: :audio,
               rtp_hdr_exts: [^audio_level_rtp_hdr_ext, ^mid_rtp_hdr_ext],
               codecs: []
             },
             %RTPTransceiver{
               mid: "1",
               direction: :recvonly,
               kind: :video,
               rtp_hdr_exts: [^mid_rtp_hdr_ext],
               codecs: [^av1_codec]
             }
           ] = PeerConnection.get_transceivers(pc)

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

    # we can't compare ids as those used in audio_video_offer are
    # different than those used by us
    assert [
             %Extmap{uri: "urn:ietf:params:rtp-hdrext:ssrc-audio-level"},
             %Extmap{uri: "urn:ietf:params:rtp-hdrext:sdes:mid"}
           ] = tr.rtp_hdr_exts

    {:ok, tr} = PeerConnection.add_transceiver(pc, :video)
    assert [%Extmap{uri: "urn:ietf:params:rtp-hdrext:sdes:mid"}] = tr.rtp_hdr_exts
    :ok = PeerConnection.close(pc)
  end
end
