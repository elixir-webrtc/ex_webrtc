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

  test "set_remote_description/2" do
    {:ok, pc} = PeerConnection.start_link()

    raw_sdp = ExSDP.new()

    audio_mline =
      ExSDP.Media.new("audio", 9, "UDP/TLS/RTP/SAVPF", [108])
      |> ExSDP.Media.add_attributes(mid: "0", ice_ufrag: "someufrag", ice_pwd: "somepwd")

    video_mline =
      ExSDP.Media.new("video", 9, "UDP/TLS/RTP/SAVPF", [96])
      |> ExSDP.Media.add_attributes(mid: "1", ice_ufrag: "someufrag", ice_pwd: "somepwd")

    sdp = ExSDP.add_media(raw_sdp, audio_mline) |> to_string()
    offer = %SessionDescription{type: :offer, sdp: sdp}
    assert {:error, :missing_bundle_group} = PeerConnection.set_remote_description(pc, offer)

    mline = ExSDP.Media.add_attribute(audio_mline, {:mid, "1"})
    sdp = ExSDP.add_media(raw_sdp, mline) |> to_string()
    offer = %SessionDescription{type: :offer, sdp: sdp}
    assert {:error, :duplicated_mid} = PeerConnection.set_remote_description(pc, offer)

    mline = ExSDP.Media.new("audio", 9, "UDP/TLS/RTP/SAVPF", [96])
    sdp = ExSDP.add_media(raw_sdp, mline) |> to_string()
    offer = %SessionDescription{type: :offer, sdp: sdp}
    assert {:error, :missing_mid} = PeerConnection.set_remote_description(pc, offer)

    sdp =
      raw_sdp
      |> ExSDP.add_attribute(%ExSDP.Attribute.Group{semantics: "BUNDLE", mids: [0]})
      |> ExSDP.add_media(audio_mline)

    offer = %SessionDescription{type: :offer, sdp: to_string(sdp)}
    assert :ok == PeerConnection.set_remote_description(pc, offer)

    sdp = ExSDP.add_media(sdp, video_mline) |> to_string()

    offer = %SessionDescription{type: :offer, sdp: sdp}

    assert {:error, :non_exhaustive_bundle_group} ==
             PeerConnection.set_remote_description(pc, offer)
  end
end
