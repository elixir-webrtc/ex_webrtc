defmodule ExWebRTC.PeerConnection.ConfigurationTest do
  use ExUnit.Case, async: true

  alias ExWebRTC.PeerConnection.Configuration
  alias ExWebRTC.RTPCodecParameters

  alias ExSDP.Attribute.{Extmap, FMTP, RTCPFeedback}

  @mid_uri "urn:ietf:params:rtp-hdrext:sdes:mid"
  @twcc_uri "http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01"
  @rid_uri "urn:ietf:params:rtp-hdrext:sdes:rtp-stream-id"
  @rrid_uri "urn:ietf:params:rtp-hdrext:sdes:repaired-rtp-stream-id"

  @mid_ext %Extmap{
    id: 1,
    uri: @mid_uri
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

  @vp9_codec %RTPCodecParameters{
    payload_type: @payload_type,
    mime_type: "video/VP9",
    clock_rate: 90_000
  }

  @rtx %RTPCodecParameters{
    payload_type: @payload_type,
    mime_type: "video/rtx",
    clock_rate: 48_000,
    sdp_fmtp_line: %FMTP{pt: @payload_type + 1, apt: @payload_type}
  }

  @opus_codec %RTPCodecParameters{
    payload_type: @payload_type,
    mime_type: "audio/opus",
    clock_rate: 48_000,
    channels: 2
  }

  describe "from_options!/1" do
    test "with everything turned off" do
      options = [
        controlling_process: self(),
        ice_servers: [],
        ice_transport_policy: :all,
        ice_ip_filter: fn _ -> true end,
        audio_codecs: [%{@opus_codec | payload_type: 111}],
        video_codecs: [%{@vp8_codec | payload_type: 100}],
        rtp_header_extensions: [%{type: :all, uri: @mid_uri}],
        rtcp_feedbacks: [],
        features: []
      ]

      config = Configuration.from_options!(options)

      assert %Configuration{
               ice_servers: [],
               ice_transport_policy: :all,
               audio_codecs: [%RTPCodecParameters{rtcp_fbs: []}],
               video_codecs: [%RTPCodecParameters{rtcp_fbs: []}],
               audio_extensions: [@mid_ext],
               video_extensions: [@mid_ext],
               features: []
             } = config
    end

    test "with TWCC enabled" do
      options = [
        controlling_process: self(),
        audio_codecs: [%{@opus_codec | payload_type: 100}],
        video_codecs: [%{@vp8_codec | payload_type: 101}],
        rtcp_feedbacks: [],
        features: [:twcc]
      ]

      config = Configuration.from_options!(options)

      assert %Configuration{
               audio_codecs: [opus],
               video_codecs: [vp8],
               audio_extensions: audio_extensions,
               video_extensions: video_extensions
             } = config

      assert Enum.any?(opus.rtcp_fbs, &(&1.feedback_type == :twcc))
      assert Enum.any?(vp8.rtcp_fbs, &(&1.feedback_type == :twcc))
      assert Enum.any?(audio_extensions, &(&1.uri == @twcc_uri))
      assert Enum.any?(video_extensions, &(&1.uri == @twcc_uri))
    end

    test "with RTX enabled" do
      options = [
        controlling_process: self(),
        video_codecs: [%{@h264_codec | payload_type: 100}, %{@vp8_codec | payload_type: 101}],
        rtcp_feedbacks: [],
        features: [:inbound_rtx, :outbound_rtx]
      ]

      config = Configuration.from_options!(options)
      assert %Configuration{video_codecs: video_codecs} = config

      assert Enum.any?(config.video_extensions, &(&1.uri == @rrid_uri))

      assert length(video_codecs) == 4

      Enum.map(video_codecs, fn %{mime_type: mime, rtcp_fbs: rtcp_fbs} ->
        if String.ends_with?(mime, "/rtx") do
          assert rtcp_fbs == []
        else
          assert Enum.any?(rtcp_fbs, &(&1.feedback_type == :nack))
        end
      end)

      [100, 101]
      |> Enum.each(fn pt ->
        assert Enum.any?(
                 video_codecs,
                 &(String.ends_with?(&1.mime_type, "/rtx") and &1.sdp_fmtp_line.apt == pt)
               )
      end)
    end

    test "with defaults" do
      config = Configuration.from_options!(controlling_process: self())

      assert %Configuration{
               video_codecs: video_codecs,
               audio_extensions: audio_extensions,
               video_extensions: video_extensions,
               features: features
             } = config

      # other tests check if these features actually have an effect
      assert Enum.sort(features) == [
               :inbound_rtx,
               :outbound_rtx,
               :rtcp_reports,
               :twcc
             ]

      assert Enum.any?(video_extensions, &(&1.uri == @mid_uri))
      assert Enum.any?(video_extensions, &(&1.uri == @rid_uri))
      assert Enum.any?(audio_extensions, &(&1.uri == @mid_uri))

      for codec <- video_codecs do
        unless String.ends_with?(codec.mime_type, "/rtx") do
          assert Enum.any?(codec.rtcp_fbs, &(&1.feedback_type == :pli))
          assert Enum.any?(codec.rtcp_fbs, &(&1.feedback_type == :fir))
        end
      end
    end
  end

  describe "update!/2" do
    test "updates RTP header extensions" do
      extensions = [
        %{type: :all, uri: @mid_uri},
        %{type: :audio, uri: @twcc_uri},
        %{type: :video, uri: @rid_uri}
      ]

      og_config =
        Configuration.from_options!(
          controlling_process: self(),
          features: [],
          rtp_header_extensions: extensions
        )

      # the ids in SDP are different than in config
      sdp =
        """
        m=audio 9 UDP/TLS/RTP/SAVPF 0
        a=extmap:1 urn:ietf:params:rtp-hdrext:ssrc-audio-level
        a=extmap:3 http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01
        a=extmap:7 urn:ietf:params:rtp-hdrext:sdes:mid
        m=video 9 UDP/TLS/RTP/SAVPF 1
        a=extmap:2 http://www.webrtc.org/experiments/rtp-hdrext/abs-send-time
        a=extmap:7 urn:ietf:params:rtp-hdrext:sdes:mid
        a=extmap:10 urn:ietf:params:rtp-hdrext:sdes:rtp-stream-id
        """
        |> ExSDP.parse!()

      config = Configuration.update(og_config, sdp)
      assert length(config.video_extensions) == 2
      assert length(config.audio_extensions) == 2

      assert %Extmap{id: 7, uri: @mid_uri} in config.audio_extensions
      assert %Extmap{id: 7, uri: @mid_uri} in config.video_extensions
      assert %Extmap{id: 10, uri: @rid_uri} in config.video_extensions
      assert %Extmap{id: 3, uri: @twcc_uri} in config.audio_extensions

      # MID is only in audio m-line
      # RID is audio m-line, but in video config
      sdp =
        """
        m=audio 9 UDP/TLS/RTP/SAVPF 0
        a=extmap:3 urn:ietf:params:rtp-hdrext:sdes:mid
        a=extmap:10 urn:ietf:params:rtp-hdrext:sdes:rtp-stream-id
        m=video 9 UDP/TLS/RTP/SAVPF 1
        a=extmap:2 http://www.webrtc.org/experiments/rtp-hdrext/abs-send-time
        """
        |> ExSDP.parse!()

      config = Configuration.update(og_config, sdp)
      assert length(config.video_extensions) == 2
      assert length(config.audio_extensions) == 2

      assert %Extmap{id: 10, uri: @rid_uri} in config.video_extensions
      assert %Extmap{id: 3, uri: @mid_uri} in config.video_extensions
      assert %Extmap{id: 3, uri: @mid_uri} in config.audio_extensions

      # TWCC in config has id 2 (automatically assigned)
      # but in SDP this id is taken over
      # so TWCC in config should change id to sometning free
      sdp =
        """
        m=audio 9 UDP/TLS/RTP/SAVPF 0
        a=extmap:2 urn:ietf:params:rtp-hdrext:sdes:rtp-stream-id
        a=extmap:5 urn:ietf:params:rtp-hdrext:sdes:mid
        m=video 9 UDP/TLS/RTP/SAVPF 1
        a=extmap:5 urn:ietf:params:rtp-hdrext:sdes:mid
        """
        |> ExSDP.parse!()

      og_twcc = Enum.find(og_config.audio_extensions, &(&1.uri == @twcc_uri))
      assert og_twcc.id == 2

      config = Configuration.update(og_config, sdp)
      assert length(config.video_extensions) == 2
      assert length(config.audio_extensions) == 2

      assert %Extmap{id: 2, uri: @rid_uri} in config.video_extensions
      assert %Extmap{id: 5, uri: @mid_uri} in config.video_extensions
      assert %Extmap{id: 5, uri: @mid_uri} in config.audio_extensions

      twcc = Enum.find(config.audio_extensions, &(&1.uri == @twcc_uri))
      assert twcc != nil and twcc.id != 2
    end

    test "updates codec payload types w/o RTX" do
      og_config =
        Configuration.from_options!(
          controlling_process: self(),
          features: [],
          video_codecs: [%{@h264_codec | payload_type: 100}, %{@vp8_codec | payload_type: 101}],
          audio_codecs: [%{@opus_codec | payload_type: 111}]
        )

      sdp =
        """
        m=audio 9 UDP/TLS/RTP/SAVPF 0
        a=rtpmap:115 opus/48000/2
        m=video 9 UDP/TLS/RTP/SAVPF 1
        a=rtpmap:100 VP8/90000
        a=rtpmap:111 H264/90000
        """
        |> ExSDP.parse!()

      config = Configuration.update(og_config, sdp)

      assert %Configuration{
               audio_codecs: [%RTPCodecParameters{payload_type: 115}],
               video_codecs: [
                 %RTPCodecParameters{payload_type: 111},
                 %RTPCodecParameters{payload_type: 100}
               ]
             } = config
    end

    test "updates codec payload types with RTX" do
      og_config =
        Configuration.from_options!(
          controlling_process: self(),
          features: [],
          audio_codecs: [],
          video_codecs: [
            %{@h264_codec | payload_type: 94},
            %{@rtx | payload_type: 111, sdp_fmtp_line: %FMTP{pt: 111, apt: 94}},
            %{@vp8_codec | payload_type: 96},
            %{@rtx | payload_type: 100, sdp_fmtp_line: %FMTP{pt: 100, apt: 96}},
            %{@vp9_codec | payload_type: 108}
          ]
        )

      # h264 and it's rtx both should change pt
      # vp8 should stay as it is but its rtx should change pt as it conflicts with the new h264
      # vp9 should just change pt
      sdp =
        """
        m=audio 9 UDP/TLS/RTP/SAVPF 0
        a=rtpmap:115 opus/48000/2
        m=video 9 UDP/TLS/RTP/SAVPF 1
        a=rtpmap:100 H264/90000
        a=rtpmap:101 rtx/90000
        a=fmtp:101 apt=100
        a=rtpmap:96 VP8/90000
        a=rtpmap:110 VP9/90000
        a=rtpmap:111 rtx/90000
        a=fmtp:111 apt=110
        """
        |> ExSDP.parse!()

      config = Configuration.update(og_config, sdp)

      assert %Configuration{
               audio_codecs: [],
               video_codecs: video_codecs
             } = config

      [h264, vp8, vp9] = Enum.reject(video_codecs, &String.ends_with?(&1.mime_type, "/rtx"))
      assert %{mime_type: "video/H264", payload_type: 100} = h264
      assert %{mime_type: "video/VP8", payload_type: 96} = vp8
      assert %{mime_type: "video/VP9", payload_type: 110} = vp9

      [h264_rtx, vp8_rtx] = Enum.filter(video_codecs, &String.ends_with?(&1.mime_type, "/rtx"))
      assert %{mime_type: "video/rtx", payload_type: 101, sdp_fmtp_line: %{apt: 100}} = h264_rtx
      assert %{mime_type: "video/rtx", payload_type: pt, sdp_fmtp_line: %{apt: 96}} = vp8_rtx
      assert pt not in [100, 101, 96, 110]
    end
  end

  test "intersect_codecs/2" do
    og_config =
      Configuration.from_options!(
        controlling_process: self(),
        audio_codecs: [%{@opus_codec | payload_type: 111}],
        video_codecs: [%{@h264_codec | payload_type: 112}, %{@vp8_codec | payload_type: 113}],
        rtcp_feedbacks: [%{type: :all, feedback: :pli}],
        features: [:inbound_rtx]
      )

    sdp =
      """
      m=audio 9 UDP/TLS/RTP/SAVPF 0
      a=rtpmap:111 opus/48000/2
      a=rtcp-fb:111 transport-cc
      m=video 9 UDP/TLS/RTP/SAVPF 1
      a=rtpmap:112 H264/90000
      a=rtcp-fb:112 transport-cc
      a=rtcp-fb:112 nack pli
      a=rtpmap:115 rtx/90000
      a=fmtp:115 apt=112
      a=rtpmap:113 VP8/90000
      a=rtcp-fb:113 transport-cc
      a=rtpmap:117 VP9/90000
      a=rtpmap:119 rtx/90000
      a=fmtp:119 apt=117
      """
      |> ExSDP.parse!()

    config = Configuration.update(og_config, sdp)

    audio_mline = Enum.find(sdp.media, &(&1.type == :audio))

    # opus should not contain any RTCP feedbacks (SDP contains TWCC, but the config does not)
    assert [opus] = Configuration.intersect_codecs(config, audio_mline)
    assert %RTPCodecParameters{mime_type: "audio/opus", payload_type: 111, rtcp_fbs: []} = opus

    video_mline = Enum.find(sdp.media, &(&1.type == :video))

    assert {[h264_rtx], [h264, vp8]} =
             config
             |> Configuration.intersect_codecs(video_mline)
             |> Enum.split_with(&String.ends_with?(&1.mime_type, "/rtx"))

    # h264 has PLI, but VP8 does not, none of the codecs has TWCC, there's no VP9 in the SDP at all
    assert %RTPCodecParameters{mime_type: "video/VP8", payload_type: 113, rtcp_fbs: []} = vp8

    assert %RTPCodecParameters{
             mime_type: "video/H264",
             payload_type: 112,
             rtcp_fbs: [%RTCPFeedback{pt: 112, feedback_type: :pli}]
           } = h264

    assert %RTPCodecParameters{
             mime_type: "video/rtx",
             payload_type: 115,
             rtcp_fbs: [],
             sdp_fmtp_line: %FMTP{pt: 115, apt: 112}
           } = h264_rtx
  end

  test "intersect_extensions/2" do
    og_config =
      Configuration.from_options!(
        controlling_process: self(),
        rtp_header_extensions: [%{type: :all, uri: @mid_uri}, %{type: :video, uri: @twcc_uri}],
        features: []
      )

    sdp =
      """
      m=audio 9 UDP/TLS/RTP/SAVPF 0
      a=extmap:14 urn:ietf:params:rtp-hdrext:sdes:mid
      a=extmap:10 urn:ietf:params:rtp-hdrext:sdes:rtp-stream-id
      a=rtpmap:111 opus/48000/2
      m=video 9 UDP/TLS/RTP/SAVPF 1
      a=extmap:5 http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01
      a=extmap:10 urn:ietf:params:rtp-hdrext:sdes:rtp-stream-id
      a=rtpmap:112 H264/90000
      """
      |> ExSDP.parse!()

    config = Configuration.update(og_config, sdp)

    audio_mline = Enum.find(sdp.media, &(&1.type == :audio))
    assert [mid] = Configuration.intersect_extensions(config, audio_mline)
    assert %Extmap{id: 14, uri: @mid_uri} = mid

    video_mline = Enum.find(sdp.media, &(&1.type == :video))
    assert [twcc] = Configuration.intersect_extensions(config, video_mline)
    assert %Extmap{id: 5, uri: @twcc_uri} = twcc
  end
end
