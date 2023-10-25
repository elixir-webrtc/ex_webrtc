defmodule ExWebRTC.PeerConnectionTest do
  use ExUnit.Case, async: true

  alias ExWebRTC.{MediaStreamTrack, PeerConnection, SessionDescription}

  @single_audio_offer """
  v=0
  o=- 6788894006044524728 2 IN IP4 127.0.0.1
  s=-
  t=0 0
  a=group:BUNDLE 0
  a=extmap-allow-mixed
  a=msid-semantic: WMS
  m=audio 9 UDP/TLS/RTP/SAVPF 111
  c=IN IP4 0.0.0.0
  a=rtcp:9 IN IP4 0.0.0.0
  a=ice-ufrag:cDua
  a=ice-pwd:v9SCmZHxJWtgpyzn8Ts1puT6
  a=ice-options:trickle
  a=fingerprint:sha-256 11:35:68:66:A4:C3:C0:AA:37:4E:0F:97:D7:9F:76:11:08:DB:56:DA:4B:83:77:50:9A:D2:71:8D:2A:A8:E3:07
  a=setup:actpass
  a=mid:0
  a=sendrecv
  a=msid:- 54f0751b-086f-433c-af40-79c179182423
  a=rtcp-mux
  a=rtpmap:111 opus/48000/2
  a=rtcp-fb:111 transport-cc
  a=fmtp:111 minptime=10;useinbandfec=1
  a=ssrc:1463342914 cname:poWwjNZ4I2ZZgzY7
  a=ssrc:1463342914 msid:- 54f0751b-086f-433c-af40-79c179182423
  """

  @audio_video_offer """
  v=0
  o=- 3253533641493747086 5 IN IP4 127.0.0.1
  s=-
  t=0 0
  a=group:BUNDLE 0 1
  a=extmap-allow-mixed
  a=msid-semantic: WMS
  m=audio 9 UDP/TLS/RTP/SAVPF 111
  c=IN IP4 0.0.0.0
  a=rtcp:9 IN IP4 0.0.0.0
  a=ice-ufrag:SOct
  a=ice-pwd:k9PRXt7zT32ADt/juUpt4Gx3
  a=ice-options:trickle
  a=fingerprint:sha-256 45:B5:2D:3A:DA:29:93:27:B6:59:F1:5B:77:62:F5:C2:CE:16:8B:12:C7:B8:34:EF:C0:12:45:17:D0:1A:E6:F4
  a=setup:actpass
  a=mid:0
  a=sendrecv
  a=msid:- 0970fb0b-4750-4302-902e-70d2e403ad0d
  a=rtcp-mux
  a=rtpmap:111 opus/48000/2
  a=rtcp-fb:111 transport-cc
  a=fmtp:111 minptime=10;useinbandfec=1
  a=ssrc:560549895 cname:QQJypppcjR+gR484
  a=ssrc:560549895 msid:- 0970fb0b-4750-4302-902e-70d2e403ad0d
  m=video 9 UDP/TLS/RTP/SAVPF 96
  c=IN IP4 0.0.0.0
  a=rtcp:9 IN IP4 0.0.0.0
  a=ice-ufrag:SOct
  a=ice-pwd:k9PRXt7zT32ADt/juUpt4Gx3
  a=ice-options:trickle
  a=fingerprint:sha-256 45:B5:2D:3A:DA:29:93:27:B6:59:F1:5B:77:62:F5:C2:CE:16:8B:12:C7:B8:34:EF:C0:12:45:17:D0:1A:E6:F4
  a=setup:actpass
  a=mid:1
  a=sendrecv
  a=msid:- 1259ea70-c6b7-445a-9c20-49cec7433ccb
  a=rtcp-mux
  a=rtcp-rsize
  a=rtpmap:96 VP8/90000
  a=rtcp-fb:96 goog-remb
  a=rtcp-fb:96 transport-cc
  a=rtcp-fb:96 ccm fir
  a=rtcp-fb:96 nack
  a=rtcp-fb:96 nack pli
  a=ssrc-group:FID 381060598 184440407
  a=ssrc:381060598 cname:QQJypppcjR+gR484
  a=ssrc:381060598 msid:- 1259ea70-c6b7-445a-9c20-49cec7433ccb
  a=ssrc:184440407 cname:QQJypppcjR+gR484
  a=ssrc:184440407 msid:- 1259ea70-c6b7-445a-9c20-49cec7433ccb
  """

  @audio_mline ExSDP.Media.new("audio", 9, "UDP/TLS/RTP/SAVPF", [108])
               |> ExSDP.Media.add_attributes(mid: "0", ice_ufrag: "someufrag", ice_pwd: "somepwd")

  @video_mline ExSDP.Media.new("video", 9, "UDP/TLS/RTP/SAVPF", [96])
               |> ExSDP.Media.add_attributes(mid: "1", ice_ufrag: "someufrag", ice_pwd: "somepwd")

  test "track notification" do
    {:ok, pc} = PeerConnection.start_link()

    offer = %SessionDescription{type: :offer, sdp: @single_audio_offer}
    :ok = PeerConnection.set_remote_description(pc, offer)

    assert_receive {:ex_webrtc, ^pc, {:track, %MediaStreamTrack{mid: "0", kind: :audio}}}

    offer = %SessionDescription{type: :offer, sdp: @audio_video_offer}
    :ok = PeerConnection.set_remote_description(pc, offer)

    assert_receive {:ex_webrtc, ^pc, {:track, %MediaStreamTrack{mid: "1", kind: :video}}}
    refute_receive {:ex_webrtc, ^pc, {:track, %MediaStreamTrack{}}}
  end

  describe "set_remote_description/2" do
    test "MID" do
      {:ok, pc} = PeerConnection.start_link()

      raw_sdp = ExSDP.new()

      mline = ExSDP.Media.add_attribute(@audio_mline, {:mid, "1"})
      sdp = ExSDP.add_media(raw_sdp, mline) |> to_string()
      offer = %SessionDescription{type: :offer, sdp: sdp}
      assert {:error, :duplicated_mid} = PeerConnection.set_remote_description(pc, offer)

      mline = ExSDP.Media.new("audio", 9, "UDP/TLS/RTP/SAVPF", [96])
      sdp = ExSDP.add_media(raw_sdp, mline) |> to_string()
      offer = %SessionDescription{type: :offer, sdp: sdp}
      assert {:error, :missing_mid} = PeerConnection.set_remote_description(pc, offer)
    end

    test "BUNDLE group" do
      {:ok, pc} = PeerConnection.start_link()

      sdp = ExSDP.add_media(ExSDP.new(), [@audio_mline, @video_mline])

      [
        {nil, {:error, :missing_bundle_group}},
        {%ExSDP.Attribute.Group{semantics: "BUNDLE", mids: [0]},
         {:error, :non_exhaustive_bundle_group}},
        {%ExSDP.Attribute.Group{semantics: "BUNDLE", mids: [0, 1]}, :ok}
      ]
      |> Enum.each(fn {bundle_group, expected_result} ->
        sdp = ExSDP.add_attribute(sdp, bundle_group) |> to_string()
        offer = %SessionDescription{type: :offer, sdp: sdp}
        assert expected_result == PeerConnection.set_remote_description(pc, offer)
      end)
    end

    test "ICE credentials" do
      {:ok, pc} = PeerConnection.start_link()

      raw_sdp = ExSDP.new()

      [
        {{nil, nil}, {"someufrag", "somepwd"}, {"someufrag", "somepwd"}, :ok},
        {{"someufrag", "somepwd"}, {"someufrag", "somepwd"}, {nil, nil}, :ok},
        {{"someufrag", "somepwd"}, {nil, nil}, {nil, nil}, :ok},
        {{"someufrag", "somepwd"}, {"someufrag", nil}, {nil, "somepwd"}, :ok},
        {{nil, nil}, {"someufrag", "somepwd"}, {nil, nil}, {:error, :missing_ice_credentials}},
        {{nil, nil}, {"someufrag", "somepwd"}, {"someufrag", nil}, {:error, :missing_ice_pwd}},
        {{nil, nil}, {"someufrag", "somepwd"}, {nil, "somepwd"}, {:error, :missing_ice_ufrag}},
        {{nil, nil}, {nil, nil}, {nil, nil}, {:error, :missing_ice_credentials}},
        {{nil, nil}, {"someufrag", "somepwd"}, {"someufrag", "someotherpwd"},
         {:error, :conflicting_ice_credentials}}
      ]
      |> Enum.each(fn {{s_ufrag, s_pwd}, {a_ufrag, a_pwd}, {v_ufrag, v_pwd}, expected_result} ->
        audio_mline =
          ExSDP.Media.new("audio", 9, "UDP/TLS/RTP/SAVPF", [108])
          |> ExSDP.Media.add_attributes(mid: "0")

        video_mline =
          ExSDP.Media.new("video", 9, "UDP/TLS/RTP/SAVPF", [96])
          |> ExSDP.Media.add_attributes(mid: "1")

        audio_mline =
          if a_ufrag do
            ExSDP.Media.add_attribute(audio_mline, {:ice_ufrag, a_ufrag})
          else
            audio_mline
          end

        audio_mline =
          if a_pwd do
            ExSDP.Media.add_attribute(audio_mline, {:ice_pwd, a_pwd})
          else
            audio_mline
          end

        video_mline =
          if v_ufrag do
            ExSDP.Media.add_attribute(video_mline, {:ice_ufrag, v_ufrag})
          else
            video_mline
          end

        video_mline =
          if v_pwd do
            ExSDP.Media.add_attribute(video_mline, {:ice_pwd, v_pwd})
          else
            video_mline
          end

        sdp =
          ExSDP.add_attribute(raw_sdp, %ExSDP.Attribute.Group{semantics: "BUNDLE", mids: [0, 1]})

        sdp =
          if s_ufrag do
            ExSDP.add_attribute(sdp, {:ice_ufrag, s_ufrag})
          else
            sdp
          end

        sdp =
          if s_pwd do
            ExSDP.add_attribute(sdp, {:ice_pwd, s_pwd})
          else
            sdp
          end

        sdp =
          sdp
          |> ExSDP.add_media([audio_mline, video_mline])
          |> to_string()

        offer = %SessionDescription{type: :offer, sdp: sdp}

        assert expected_result == PeerConnection.set_remote_description(pc, offer)
      end)
    end
  end
end
