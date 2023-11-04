defmodule ExWebRTC.PeerConnectionTest do
  use ExUnit.Case, async: true

  alias ExWebRTC.{MediaStreamTrack, PeerConnection, SessionDescription}

  @audio_mline ExSDP.Media.new("audio", 9, "UDP/TLS/RTP/SAVPF", [108])
               |> ExSDP.Media.add_attributes(mid: "0", ice_ufrag: "someufrag", ice_pwd: "somepwd")

  @video_mline ExSDP.Media.new("video", 9, "UDP/TLS/RTP/SAVPF", [96])
               |> ExSDP.Media.add_attributes(mid: "1", ice_ufrag: "someufrag", ice_pwd: "somepwd")

  test "track notification" do
    {:ok, pc} = PeerConnection.start_link()

    offer = %SessionDescription{type: :offer, sdp: File.read!("test/fixtures/audio_sdp.txt")}
    :ok = PeerConnection.set_remote_description(pc, offer)

    assert_receive {:ex_webrtc, ^pc, {:track, %MediaStreamTrack{mid: "0", kind: :audio}}}

    offer = %SessionDescription{
      type: :offer,
      sdp: File.read!("test/fixtures/audio_video_sdp.txt")
    }

    :ok = PeerConnection.set_remote_description(pc, offer)

    assert_receive {:ex_webrtc, ^pc, {:track, %MediaStreamTrack{mid: "1", kind: :video}}}
    refute_receive {:ex_webrtc, ^pc, {:track, %MediaStreamTrack{}}}
  end

  test "offer/answer exchange" do
    {:ok, pc1} = PeerConnection.start_link()
    {:ok, _} = PeerConnection.add_transceiver(pc1, :audio)
    {:ok, offer} = PeerConnection.create_offer(pc1)
    :ok = PeerConnection.set_local_description(pc1, offer)

    {:ok, pc2} = PeerConnection.start_link()
    :ok = PeerConnection.set_remote_description(pc2, offer)
    {:ok, answer} = PeerConnection.create_answer(pc2)
    :ok = PeerConnection.set_local_description(pc2, answer)

    :ok = PeerConnection.set_remote_description(pc1, answer)
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
