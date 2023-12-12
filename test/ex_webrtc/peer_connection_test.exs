defmodule ExWebRTC.PeerConnectionTest do
  use ExUnit.Case, async: true

  alias ExWebRTC.{MediaStreamTrack, PeerConnection, SessionDescription, SDPUtils, Utils}

  {_pkey, cert} = ExDTLS.generate_key_cert()

  @fingerprint cert
               |> ExDTLS.get_cert_fingerprint()
               |> Utils.hex_dump()

  @audio_mline ExSDP.Media.new("audio", 9, "UDP/TLS/RTP/SAVPF", [108])
               |> ExSDP.Media.add_attribute(:rtcp_mux)
               |> ExSDP.Media.add_attributes(
                 setup: :active,
                 mid: "0",
                 ice_ufrag: "someufrag",
                 ice_pwd: "somepwd",
                 fingerprint: {:sha256, @fingerprint}
               )

  @video_mline ExSDP.Media.new("video", 9, "UDP/TLS/RTP/SAVPF", [96])
               |> ExSDP.Media.add_attribute(:rtcp_mux)
               |> ExSDP.Media.add_attributes(
                 setup: :active,
                 mid: "1",
                 ice_ufrag: "someufrag",
                 ice_pwd: "somepwd",
                 fingerprint: {:sha256, @fingerprint}
               )

  test "track notification" do
    {:ok, pc} = PeerConnection.start_link()

    offer = %SessionDescription{type: :offer, sdp: File.read!("test/fixtures/audio_sdp.txt")}
    :ok = PeerConnection.set_remote_description(pc, offer)

    assert_receive {:ex_webrtc, ^pc, {:track, %MediaStreamTrack{kind: :audio}}}

    {:ok, answer} = PeerConnection.create_answer(pc)
    :ok = PeerConnection.set_local_description(pc, answer)

    offer = %SessionDescription{
      type: :offer,
      sdp: File.read!("test/fixtures/audio_video_sdp.txt")
    }

    :ok = PeerConnection.set_remote_description(pc, offer)

    assert_receive {:ex_webrtc, ^pc, {:track, %MediaStreamTrack{kind: :video}}}
    refute_receive {:ex_webrtc, ^pc, {:track, %MediaStreamTrack{}}}
  end

  test "signaling state change" do
    {:ok, pc1} = PeerConnection.start_link()
    assert_receive {:ex_webrtc, ^pc1, {:signaling_state_change, :stable}}

    {:ok, _} = PeerConnection.add_transceiver(pc1, :audio)
    {:ok, offer} = PeerConnection.create_offer(pc1)
    :ok = PeerConnection.set_local_description(pc1, offer)
    assert_receive {:ex_webrtc, ^pc1, {:signaling_state_change, :have_local_offer}}

    {:ok, pc2} = PeerConnection.start_link()
    assert_receive {:ex_webrtc, ^pc2, {:signaling_state_change, :stable}}

    :ok = PeerConnection.set_remote_description(pc2, offer)
    assert_receive {:ex_webrtc, ^pc2, {:signaling_state_change, :have_remote_offer}}

    {:ok, answer} = PeerConnection.create_answer(pc2)
    :ok = PeerConnection.set_local_description(pc2, answer)
    assert_receive {:ex_webrtc, ^pc2, {:signaling_state_change, :stable}}

    :ok = PeerConnection.set_remote_description(pc1, answer)
    assert_receive {:ex_webrtc, ^pc1, {:signaling_state_change, :stable}}
  end

  test "connection state change" do
    {:ok, pc1} = PeerConnection.start_link()
    assert_receive {:ex_webrtc, ^pc1, {:connection_state_change, :new}}
    {:ok, _} = PeerConnection.add_transceiver(pc1, :audio)
    {:ok, offer} = PeerConnection.create_offer(pc1)
    :ok = PeerConnection.set_local_description(pc1, offer)

    {:ok, pc2} = PeerConnection.start_link()
    assert_receive {:ex_webrtc, ^pc2, {:connection_state_change, :new}}
    :ok = PeerConnection.set_remote_description(pc2, offer)
    {:ok, answer} = PeerConnection.create_answer(pc2)
    :ok = PeerConnection.set_local_description(pc2, answer)

    :ok = PeerConnection.set_remote_description(pc1, answer)

    assert :ok ==
             check_connection_state_change(
               pc1,
               pc2,
               %{
                 connecting_recv: false,
                 connected_recv: false
               },
               %{
                 connecting_recv: false,
                 connected_recv: false
               }
             )
  end

  defp check_connection_state_change(
         _pc1,
         _pc2,
         %{
           connecting_recv: true,
           connected_recv: true
         },
         %{
           connecting_recv: true,
           connected_recv: true
         }
       ),
       do: :ok

  defp check_connection_state_change(pc1, pc2, pc1_states, pc2_states) do
    receive do
      {:ex_webrtc, ^pc1, {:ice_candidate, cand}} ->
        :ok = PeerConnection.add_ice_candidate(pc2, cand)
        check_connection_state_change(pc1, pc2, pc1_states, pc2_states)

      {:ex_webrtc, ^pc2, {:ice_candidate, cand}} ->
        :ok = PeerConnection.add_ice_candidate(pc1, cand)
        check_connection_state_change(pc1, pc2, pc1_states, pc2_states)

      {:ex_webrtc, ^pc1, {:connection_state_change, :connecting}}
      when pc1_states.connecting_recv == false and pc1_states.connected_recv == false ->
        check_connection_state_change(pc1, pc2, %{pc1_states | connecting_recv: true}, pc2_states)

      {:ex_webrtc, ^pc1, {:connection_state_change, :connecting}} = msg ->
        raise "Unexpectedly received: #{inspect(msg)}, when pc_states is: #{inspect(pc1_states)}"

      {:ex_webrtc, ^pc2, {:connection_state_change, :connecting}}
      when pc2_states.connecting_recv == false and pc2_states.connected_recv == false ->
        check_connection_state_change(pc1, pc2, pc1_states, %{pc2_states | connecting_recv: true})

      {:ex_webrtc, ^pc2, {:connection_state_change, :connecting}} = msg ->
        raise "Unexpectedly received: #{inspect(msg)}, when pc_states is: #{inspect(pc2_states)}"

      {:ex_webrtc, ^pc1, {:connection_state_change, :connected}}
      when pc1_states.connecting_recv == true and pc1_states.connected_recv == false ->
        check_connection_state_change(pc1, pc2, %{pc1_states | connected_recv: true}, pc2_states)

      {:ex_webrtc, ^pc1, {:connection_state_change, :connected}} = msg ->
        raise "Unexpectedly received: #{inspect(msg)}, when pc_states is: #{inspect(pc1_states)}"

      {:ex_webrtc, ^pc2, {:connection_state_change, :connected}}
      when pc2_states.connecting_recv == true and pc2_states.connected_recv == false ->
        check_connection_state_change(pc1, pc2, pc1_states, %{pc2_states | connected_recv: true})

      {:ex_webrtc, ^pc2, {:connection_state_change, :connected}} = msg ->
        raise "Unexpectedly received: #{inspect(msg)}, when pc_states is: #{inspect(pc2_states)}"

      {:ex_webrtc, ^pc1, {:connection_state_change, _state}} = msg ->
        raise "Unexpectedly received: #{inspect(msg)}, when pc_states is: #{inspect(pc1_states)}"

      {:ex_webrtc, ^pc2, {:connection_state_change, _state}} = msg ->
        raise "Unexpectedly received: #{inspect(msg)}, when pc_states is: #{inspect(pc2_states)}"
    end
  end

  describe "set_remote_description/2" do
    test "MID" do
      {:ok, pc} = PeerConnection.start_link()

      raw_sdp = ExSDP.new()

      mline = ExSDP.Media.add_attribute(@audio_mline, {:mid, "1"})
      sdp = ExSDP.add_media(raw_sdp, mline) |> to_string()
      offer = %SessionDescription{type: :offer, sdp: sdp}
      assert {:error, :duplicated_mid} = PeerConnection.set_remote_description(pc, offer)

      mline = SDPUtils.delete_attribute(@audio_mline, :mid)
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

      audio_mline = SDPUtils.delete_attributes(@audio_mline, [:ice_ufrag, :ice_pwd])
      video_mline = SDPUtils.delete_attributes(@video_mline, [:ice_ufrag, :ice_pwd])

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

    test "cert fingerprint" do
      {:ok, pc} = PeerConnection.start_link()
      raw_sdp = ExSDP.new()

      audio_mline = SDPUtils.delete_attribute(@audio_mline, :fingerprint)
      video_mline = SDPUtils.delete_attribute(@video_mline, :fingerprint)

      [
        {{:sha256, @fingerprint}, {:sha256, @fingerprint}, {:sha256, @fingerprint}, :ok},
        {nil, {:sha256, @fingerprint}, {:sha256, @fingerprint}, :ok},
        {{:sha256, @fingerprint}, nil, {:sha256, @fingerprint},
         {:error, :missing_cert_fingerprint}},
        {nil, {:sha256, @fingerprint}, nil, {:error, :missing_cert_fingerprint}},
        {nil, {:sha256, @fingerprint}, {:sha1, @fingerprint},
         {:error, :conflicting_cert_fingerprints}},
        {nil, {:sha1, @fingerprint}, {:sha1, @fingerprint},
         {:error, :unsupported_cert_fingerprint_hash_function}}
      ]
      |> Enum.each(fn {s_fingerprint, a_fingerprint, v_fingerprint, expected_result} ->
        audio_mline =
          if a_fingerprint do
            ExSDP.Media.add_attribute(audio_mline, {:fingerprint, a_fingerprint})
          else
            audio_mline
          end

        video_mline =
          if v_fingerprint do
            ExSDP.Media.add_attribute(video_mline, {:fingerprint, v_fingerprint})
          else
            video_mline
          end

        sdp =
          ExSDP.add_attribute(raw_sdp, %ExSDP.Attribute.Group{semantics: "BUNDLE", mids: [0, 1]})

        sdp =
          if s_fingerprint do
            ExSDP.add_attribute(sdp, {:fingerprint, s_fingerprint})
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

  test "sends basic data" do
    {:ok, pc1} = PeerConnection.start_link()
    %MediaStreamTrack{id: id1} = track = ExWebRTC.MediaStreamTrack.new(:video)
    {:ok, _} = PeerConnection.add_transceiver(pc1, track)
    {:ok, offer} = PeerConnection.create_offer(pc1)
    :ok = PeerConnection.set_local_description(pc1, offer)

    {:ok, pc2} = PeerConnection.start_link()
    :ok = PeerConnection.set_remote_description(pc2, offer)
    {:ok, answer} = PeerConnection.create_answer(pc2)
    :ok = PeerConnection.set_local_description(pc2, answer)
    :ok = PeerConnection.set_remote_description(pc1, answer)
    assert_receive {:ex_webrtc, ^pc2, {:track, %MediaStreamTrack{kind: :video, id: id2}}}

    assert_receive {:ex_webrtc, ^pc2, {:ice_candidate, candidate}}
    :ok = PeerConnection.add_ice_candidate(pc1, candidate)

    assert_receive {:ex_webrtc, ^pc1, {:connection_state_change, :connected}}
    payload = <<3, 2, 5>>
    packet = ExRTP.Packet.new(payload, 111, 50_000, 3_000, 5_000)
    :ok = PeerConnection.send_rtp(pc1, id1, packet)

    assert_receive {:ex_webrtc, ^pc2, {:rtp, ^id2, %ExRTP.Packet{payload: ^payload}}}
  end
end
