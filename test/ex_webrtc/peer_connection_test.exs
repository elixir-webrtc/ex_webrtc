defmodule ExWebRTC.PeerConnectionTest do
  use ExUnit.Case, async: true

  alias ExWebRTC.{
    RTPTransceiver,
    RTPSender,
    MediaStreamTrack,
    PeerConnection,
    SessionDescription,
    Utils
  }

  {_pkey, cert} = ExDTLS.generate_key_cert()

  @fingerprint cert
               |> ExDTLS.get_cert_fingerprint()
               |> Utils.hex_dump()

  @audio_mline ExSDP.Media.new("audio", 9, "UDP/TLS/RTP/SAVPF", [108])
               |> ExSDP.add_attribute(:rtcp_mux)
               |> ExSDP.add_attributes(
                 setup: :active,
                 mid: "0",
                 ice_ufrag: "someufrag",
                 ice_pwd: "somepwd",
                 fingerprint: {:sha256, @fingerprint}
               )

  @video_mline ExSDP.Media.new("video", 9, "UDP/TLS/RTP/SAVPF", [96])
               |> ExSDP.add_attribute(:rtcp_mux)
               |> ExSDP.add_attributes(
                 setup: :active,
                 mid: "1",
                 ice_ufrag: "someufrag",
                 ice_pwd: "somepwd",
                 fingerprint: {:sha256, @fingerprint}
               )

  describe "track notifications" do
    test "are emitted on new remote track" do
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

    test "are not emitted for the same track twice" do
      {:ok, pc} = PeerConnection.start_link()

      offer = %SessionDescription{type: :offer, sdp: File.read!("test/fixtures/audio_sdp.txt")}
      :ok = PeerConnection.set_remote_description(pc, offer)

      assert_receive {:ex_webrtc, ^pc, {:track, %MediaStreamTrack{kind: :audio}}}

      {:ok, answer} = PeerConnection.create_answer(pc)
      :ok = PeerConnection.set_local_description(pc, answer)

      :ok = PeerConnection.set_remote_description(pc, offer)
      refute_receive {:ex_webrtc, ^pc, {:track, %MediaStreamTrack{}}}
    end
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

      mline = ExSDP.add_attribute(@audio_mline, {:mid, "1"})
      sdp = ExSDP.add_media(raw_sdp, mline) |> to_string()
      offer = %SessionDescription{type: :offer, sdp: sdp}
      assert {:error, :duplicated_mid} = PeerConnection.set_remote_description(pc, offer)

      mline = ExSDP.delete_attribute(@audio_mline, :mid)
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

      audio_mline = ExSDP.delete_attributes(@audio_mline, [:ice_ufrag, :ice_pwd])
      video_mline = ExSDP.delete_attributes(@video_mline, [:ice_ufrag, :ice_pwd])

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
            ExSDP.add_attribute(audio_mline, {:ice_ufrag, a_ufrag})
          else
            audio_mline
          end

        audio_mline =
          if a_pwd do
            ExSDP.add_attribute(audio_mline, {:ice_pwd, a_pwd})
          else
            audio_mline
          end

        video_mline =
          if v_ufrag do
            ExSDP.add_attribute(video_mline, {:ice_ufrag, v_ufrag})
          else
            video_mline
          end

        video_mline =
          if v_pwd do
            ExSDP.add_attribute(video_mline, {:ice_pwd, v_pwd})
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

      audio_mline = ExSDP.delete_attribute(@audio_mline, :fingerprint)
      video_mline = ExSDP.delete_attribute(@video_mline, :fingerprint)

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
            ExSDP.add_attribute(audio_mline, {:fingerprint, a_fingerprint})
          else
            audio_mline
          end

        video_mline =
          if v_fingerprint do
            ExSDP.add_attribute(video_mline, {:fingerprint, v_fingerprint})
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

  describe "add_track/2" do
    test "with no available transceivers" do
      {:ok, pc} = PeerConnection.start_link()
      track = MediaStreamTrack.new(:audio)

      assert {:ok, sender} = PeerConnection.add_track(pc, track)
      assert sender.track == track

      assert [transceiver] = PeerConnection.get_transceivers(pc)
      assert %RTPTransceiver{sender: ^sender, direction: :sendrecv} = transceiver
    end

    test "with transceiver available" do
      {:ok, tmp_pc} = PeerConnection.start_link()
      {:ok, _tr} = PeerConnection.add_transceiver(tmp_pc, :audio, direction: :sendonly)
      {:ok, offer} = PeerConnection.create_offer(tmp_pc)

      {:ok, pc} = PeerConnection.start_link()
      :ok = PeerConnection.set_remote_description(pc, offer)
      {:ok, answer} = PeerConnection.create_answer(pc)
      :ok = PeerConnection.set_local_description(pc, answer)

      assert [
               %RTPTransceiver{
                 current_direction: :recvonly,
                 sender: %RTPSender{track: nil}
               }
             ] = PeerConnection.get_transceivers(pc)

      track = MediaStreamTrack.new(:audio)
      assert {:ok, sender} = PeerConnection.add_track(pc, track)
      assert sender.track == track

      assert [transceiver] = PeerConnection.get_transceivers(pc)
      assert %RTPTransceiver{sender: ^sender, direction: :sendrecv} = transceiver
    end

    test "won't choose inappropriate transceiver" do
      {:ok, pc} = PeerConnection.start_link()
      {:ok, tr} = PeerConnection.add_transceiver(pc, MediaStreamTrack.new(:audio))

      track = MediaStreamTrack.new(:audio)
      assert {:ok, sender} = PeerConnection.add_track(pc, track)
      assert sender.track == track

      assert [^tr, transceiver] = PeerConnection.get_transceivers(pc)
      assert %RTPTransceiver{sender: ^sender, direction: :sendrecv} = transceiver
    end
  end

  test "can exchange data on single transceiver" do
    # setup track pc1 -> pc2
    {:ok, pc1} = PeerConnection.start_link()
    track1 = MediaStreamTrack.new(:audio)
    {:ok, _sender} = PeerConnection.add_track(pc1, track1)
    {:ok, offer} = PeerConnection.create_offer(pc1)
    :ok = PeerConnection.set_local_description(pc1, offer)

    {:ok, pc2} = PeerConnection.start_link()
    :ok = PeerConnection.set_remote_description(pc2, offer)
    {:ok, answer} = PeerConnection.create_answer(pc2)
    :ok = PeerConnection.set_local_description(pc2, answer)

    :ok = PeerConnection.set_remote_description(pc1, answer)

    # setup track pc2 -> pc1
    track2 = MediaStreamTrack.new(:audio)
    {:ok, _sender} = PeerConnection.add_track(pc2, track2)
    {:ok, offer} = PeerConnection.create_offer(pc2)
    :ok = PeerConnection.set_local_description(pc2, offer)

    :ok = PeerConnection.set_remote_description(pc1, offer)
    {:ok, answer} = PeerConnection.create_answer(pc1)
    :ok = PeerConnection.set_local_description(pc1, answer)

    :ok = PeerConnection.set_remote_description(pc2, answer)

    # exchange ICE candidates
    assert_receive {:ex_webrtc, ^pc1, {:ice_candidate, candidate}}
    :ok = PeerConnection.add_ice_candidate(pc2, candidate)
    assert_receive {:ex_webrtc, ^pc2, {:ice_candidate, candidate}}
    :ok = PeerConnection.add_ice_candidate(pc1, candidate)

    # wait to establish connection
    assert_receive {:ex_webrtc, ^pc1, {:connection_state_change, :connected}}
    assert_receive {:ex_webrtc, ^pc2, {:connection_state_change, :connected}}

    # receive track info
    assert_receive {:ex_webrtc, ^pc1, {:track, %MediaStreamTrack{kind: :audio, id: id1}}}
    assert_receive {:ex_webrtc, ^pc2, {:track, %MediaStreamTrack{kind: :audio, id: id2}}}

    # check transceivers
    assert [tr1] = PeerConnection.get_transceivers(pc1)
    assert [tr2] = PeerConnection.get_transceivers(pc1)

    assert tr1.mid == tr2.mid
    assert tr1.current_direction == :sendrecv
    assert tr2.current_direction == :sendrecv

    # send data
    payload = <<3, 2, 5>>
    packet = ExRTP.Packet.new(payload, 111, 50_000, 3_000, 5_000)
    :ok = PeerConnection.send_rtp(pc1, track1.id, packet)

    assert_receive {:ex_webrtc, ^pc2, {:rtp, ^id2, %ExRTP.Packet{payload: ^payload}}}

    payload = <<7, 8, 9>>
    packet = ExRTP.Packet.new(payload, 111, 50_000, 3_000, 5_000)
    :ok = PeerConnection.send_rtp(pc2, track2.id, packet)

    assert_receive {:ex_webrtc, ^pc1, {:rtp, ^id1, %ExRTP.Packet{payload: ^payload}}}
  end

  test "updates rtp header extension ids and payload types" do
    # check wheter we update our RTP header extension ids
    # and payload types when we receive a remote offer with different ones
    {:ok, pc1} = PeerConnection.start_link()
    {:ok, _} = PeerConnection.add_transceiver(pc1, :audio)
    {:ok, offer} = PeerConnection.create_offer(pc1)

    sdp = ExSDP.parse!(offer.sdp)

    # munge Extmap and RTPMappingsso so that we use different ids and pts
    [mline] = sdp.media

    extmaps =
      mline
      |> ExSDP.get_attributes(:extmap)
      |> Enum.map(fn extmap -> %{extmap | id: extmap.id + 1} end)

    rtp_mappings =
      mline
      |> ExSDP.get_attributes(:rtpmap)
      |> Enum.map(fn rtp_mapping ->
        %{rtp_mapping | payload_type: rtp_mapping.payload_type + 1}
      end)

    fmtps =
      mline
      |> ExSDP.get_attributes(:fmtp)
      |> Enum.map(fn fmtp -> %{fmtp | pt: fmtp.pt + 1} end)

    mline =
      mline
      |> ExSDP.delete_attributes([:extmap, :rtpmap, :fmtp])
      |> ExSDP.add_attributes(extmaps ++ rtp_mappings ++ fmtps)

    sdp = %{sdp | media: [mline]}

    offer = %SessionDescription{type: :offer, sdp: to_string(sdp)}

    {:ok, pc2} = PeerConnection.start_link()
    :ok = PeerConnection.set_remote_description(pc2, offer)
    {:ok, answer} = PeerConnection.create_answer(pc2)
    :ok = PeerConnection.set_local_description(pc2, answer)

    {:ok, _} = PeerConnection.add_transceiver(pc2, :audio)
    {:ok, offer} = PeerConnection.create_offer(pc2)

    [audio1, audio2] = ExSDP.parse!(offer.sdp).media

    assert ExSDP.get_attributes(audio1, :extmap) ==
             ExSDP.get_attributes(audio2, :extmap)

    assert ExSDP.get_attributes(audio1, :rtpmap) ==
             ExSDP.get_attributes(audio2, :rtpmap)

    assert ExSDP.get_attributes(audio1, :fmtp) == ExSDP.get_attributes(audio2, :fmtp)

    :ok = PeerConnection.close(pc1)
    :ok = PeerConnection.close(pc2)
  end
end
