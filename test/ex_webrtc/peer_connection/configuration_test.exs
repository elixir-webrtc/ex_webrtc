defmodule ExWebRTC.PeerConnection.ConfigurationTest do
  use ExUnit.Case, async: true

  alias ExWebRTC.{PeerConnection, RTPCodecParameters, RTPTransceiver, SessionDescription}
  alias ExWebRTC.PeerConnection.Configuration

  alias ExSDP.Attribute.Extmap

  @twcc_uri "http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01"
  @rid_uri "urn:ietf:params:rtp-hdrext:sdes:rtp-stream-id"
  @rrid_uri "urn:ietf:params:rtp-hdrext:sdes:repaired-rtp-stream-id"

  @extension_id 1
  @mid_ext %Extmap{
    id: @extension_id,
    uri: "urn:ietf:params:rtp-hdrext:sdes:mid"
  }

  @rid_ext %Extmap{
    id: @extension_id,
    uri: "urn:ietf:params:rtp-hdrext:sdes:rtp-stream-id"
  }

  @payload_type 100
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

  describe "from_options!/1" do
    test "with invalid options" do
      # no MID
      options = [header_extensions: []]
      assert_raise RuntimeError, fn -> Configuration.from_options!(options) end

      # duplicate payload types
      options = [video_codecs: [@h264_codec, @vp8_codec]]
      assert_raise RuntimeError, fn -> Configuration.from_options!(options) end

      # duplicate RTP header extension ids
      options = [
        header_extensions: [%{type: :all, extmap: @mid_ext}, %{type: :video, extmap: @rid_ext}]
      ]

      assert_raise RuntimeError, fn -> Configuration.from_options!(options) end

      # duplicate RTCP feedbacks
      options = [feedbacks: [%{type: :all, feedback: :nack}, %{type: :video, feedback: :nack}]]
      assert_raise RuntimeError, fn -> Configuration.from_options!(options) end
    end

    test "with everything turned off" do
      options = [
        controlling_process: self(),
        ice_servers: [],
        ice_transport_policy: :all,
        ice_ip_filetr: fn _ -> true end,
        audio_codecs: [],
        video_codecs: [],
        header_extensions: [%{type: :audio, extmap: @mid_ext}],
        feedbacks: [],
        features: []
      ]

      config = Configuration.from_options!(options)

      assert %Configuration{
               controlling_process: self(),
               ice_servers: [],
               ice_transport_policy: :all,
               ice_ip_filter: fn _ -> true end,
               audio_codecs: [],
               video_codecs: [],
               header_extensions: [%{type: :audio, extmap: @mid_ext}],
               feedbacks: [],
               features: []
             } == config
    end

    test "with features" do
      options = [
        feedbacks: [],
        features: [:twcc]
      ]

      config = Configuration.from_options!(options)

      assert %Configuration{
               header_extensions: header_extensions,
               feedbacks: feedbacks
             } = config

      assert %{type: :all, feedback: :twcc} in feedbacks
      assert Enum.any?(header_extensions, &(&1.type == :all and &1.extmap.uri == @twcc_uri))

      pt1 = 100
      pt2 = 101

      options = [
        video_codecs: [%{@h264_codec | payload_type: pt1}, %{@vp8_codec | payload_type: pt2}],
        feedbacks: [],
        features: [:inbound_rtx, :outbound_rtx]
      ]

      config = Configuration.from_options!(options)

      assert %Configuration{
               video_codecs: video_codecs,
               feedbacks: feedbacks
             } = config

      assert %{type: :video, feedback: :nack} in feedbacks
      assert length(video_codecs) == 4

      [pt1, pt2]
      |> Enum.each(fn pt ->
        assert Enum.any?(
                 video_codecs,
                 &(&1.mime_type == "rtx/video" and &1.sdp_fmtp_line.apt == pt)
               )
      end)

      options = [
        feedbacks: [],
        features: [:inbound_simulcast]
      ]

      config = Configuration.from_options!(options)

      assert %Configuration{
               header_extensions: header_extensions
             } = config

      [@rid_uri, @rrid_uri]
      |> Enum.each(fn uri ->
        assert Enum.any?(header_extensions, &(&1.type == :video and &1.extmap.uri == uri))
      end)
    end

    test "with defaults" do
      config = Configuration.from_options!([])

      assert %Configuration{
               feedbacks: feedbacks,
               features: features
             } = config

      assert Enum.sort(features) == [
               :inbound_rtx,
               :inbound_simulcast,
               :outbound_rtx,
               :reports,
               :twcc
             ]

      assert %{type: :video, feedback: :pli} in feedbacks
      assert %{type: :video, feedback: :fir} in feedbacks
    end
  end

  # test "codecs and rtp hdr extensions" do
  #   # default audio and video codecs
  #   # assert there are only them - no g711 or others
  #   {:ok, pc} = PeerConnection.start_link()
  #
  #   offer = %SessionDescription{
  #     type: :offer,
  #     sdp: File.read!("test/fixtures/sdp/chromium_audio_video_sdp.txt")
  #   }
  #
  #   assert :ok = PeerConnection.set_remote_description(pc, offer)
  #   transceivers = PeerConnection.get_transceivers(pc)
  #
  #   assert [
  #            %RTPTransceiver{
  #              mid: "0",
  #              direction: :recvonly,
  #              kind: :audio,
  #              rtp_hdr_exts: [@twcc_rtp_hdr_ext, @mid_rtp_hdr_ext],
  #              codecs: audio_codecs
  #            },
  #            %RTPTransceiver{
  #              mid: "1",
  #              direction: :recvonly,
  #              kind: :video,
  #              rtp_hdr_exts: [
  #                @twcc_rtp_hdr_ext,
  #                @mid_rtp_hdr_ext,
  #                @rid_rtp_hdr_ext,
  #                @rrid_rtp_hdr_ext
  #              ],
  #              codecs: video_codecs
  #            }
  #          ] = transceivers
  #
  #   assert Enum.all?(audio_codecs, fn codec ->
  #            %{codec | payload_type: @payload_type, sdp_fmtp_line: nil, rtcp_fbs: []} in @audio_codecs
  #          end)
  #
  #   assert Enum.all?(video_codecs, fn codec ->
  #            %{codec | payload_type: @payload_type, sdp_fmtp_line: nil, rtcp_fbs: []} in @video_codecs
  #          end)
  #
  #   assert :ok = PeerConnection.close(pc)
  #
  #   # audio level rtp hdr ext, no audio codecs and one video codec
  #   # assert there are no audio, h264 and vp8 codecs, and there is audio level
  #   # rtp hdr extension
  #   {:ok, pc} =
  #     PeerConnection.start_link(
  #       audio_codecs: [],
  #       video_codecs: [@av1_codec],
  #       rtp_hdr_extensions: [:audio_level]
  #     )
  #
  #   offer = %SessionDescription{
  #     type: :offer,
  #     sdp: File.read!("test/fixtures/sdp/chromium_audio_video_sdp.txt")
  #   }
  #
  #   assert :ok = PeerConnection.set_remote_description(pc, offer)
  #
  #   assert [
  #            %ExWebRTC.RTPTransceiver{
  #              mid: "0",
  #              direction: :recvonly,
  #              kind: :audio,
  #              rtp_hdr_exts: [@audio_level_rtp_hdr_ext, @twcc_rtp_hdr_ext, @mid_rtp_hdr_ext],
  #              codecs: []
  #            },
  #            %RTPTransceiver{
  #              mid: "1",
  #              direction: :recvonly,
  #              kind: :video,
  #              rtp_hdr_exts: [
  #                @twcc_rtp_hdr_ext,
  #                @mid_rtp_hdr_ext,
  #                @rid_rtp_hdr_ext,
  #                @rrid_rtp_hdr_ext
  #              ],
  #              codecs: video_codecs
  #            }
  #          ] = PeerConnection.get_transceivers(pc)
  #
  #   assert Enum.all?(video_codecs, fn codec ->
  #            %{codec | payload_type: @payload_type, sdp_fmtp_line: nil, rtcp_fbs: []} ==
  #              @av1_codec
  #          end)
  #
  #   {:ok, answer} = PeerConnection.create_answer(pc)
  #   sdp = ExSDP.parse!(answer.sdp)
  #
  #   # assert that audio mline has been rejected
  #   # as we didn't add any supported audio codecs
  #   assert List.first(sdp.media).port == 0
  #   assert :ok = PeerConnection.close(pc)
  #
  #   # additional audio level header extension
  #   # assert it is only present in audio transceiver
  #   {:ok, pc} = PeerConnection.start_link(rtp_hdr_extensions: [:audio_level])
  #   {:ok, tr} = PeerConnection.add_transceiver(pc, :audio)
  #   tr_rtp_hdr_exts = Enum.map(tr.rtp_hdr_exts, & &1.uri) |> MapSet.new()
  #
  #   assert MapSet.new([
  #            "http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01",
  #            "urn:ietf:params:rtp-hdrext:ssrc-audio-level",
  #            "urn:ietf:params:rtp-hdrext:sdes:mid"
  #          ]) == tr_rtp_hdr_exts
  #
  #   {:ok, tr} = PeerConnection.add_transceiver(pc, :video)
  #   tr_rtp_hdr_exts = Enum.map(tr.rtp_hdr_exts, & &1.uri) |> MapSet.new()
  #
  #   assert MapSet.new([
  #            "http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01",
  #            "urn:ietf:params:rtp-hdrext:sdes:mid",
  #            "urn:ietf:params:rtp-hdrext:sdes:rtp-stream-id",
  #            "urn:ietf:params:rtp-hdrext:sdes:repaired-rtp-stream-id"
  #          ]) == tr_rtp_hdr_exts
  #
  #   :ok = PeerConnection.close(pc)
  # end

  test "properly handles RTX" do
    video_codecs = [
      %RTPCodecParameters{
        payload_type: 100,
        mime_type: "video/VP8",
        clock_rate: 90_000
      },
      %RTPCodecParameters{
        payload_type: 105,
        mime_type: "video/rtx",
        clock_rate: 90_000,
        sdp_fmtp_line: %{pt: 105, apt: 100}
      }
    ]

    {:ok, pc} =
      PeerConnection.start_link(
        video_codecs: video_codecs,
        audio_codecs: []
      )

    # in the SDP, codecs and rtx have different payload types
    offer = %SessionDescription{
      type: :offer,
      sdp: File.read!("test/fixtures/sdp/chromium_audio_video_sdp.txt")
    }

    :ok = PeerConnection.set_remote_description(pc, offer)
    {:ok, answer} = PeerConnection.create_answer(pc)
    :ok = PeerConnection.set_local_description(pc, answer)

    assert [%RTPTransceiver{kind: :video, codecs: codecs}] = PeerConnection.get_transceivers(pc)

    assert [
             %RTPCodecParameters{
               mime_type: "video/VP8",
               payload_type: 96
             },
             %RTPCodecParameters{
               mime_type: "video/rtx",
               payload_type: 97,
               sdp_fmtp_line: %{pt: 97, apt: 96}
             }
           ] = codecs
  end
end
