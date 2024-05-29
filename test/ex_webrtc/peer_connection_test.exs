defmodule ExWebRTC.PeerConnectionTest do
  use ExUnit.Case, async: true

  import ExWebRTC.Support.TestUtils

  alias ExWebRTC.{
    RTPTransceiver,
    RTPSender,
    MediaStreamTrack,
    PeerConnection,
    RTPCodecParameters,
    SessionDescription,
    Utils
  }

  {_pkey, cert} = ExDTLS.generate_key_cert()

  @fingerprint cert
               |> ExDTLS.get_cert_fingerprint()
               |> Utils.hex_dump()

  @audio_mline ExSDP.Media.new("audio", 9, "UDP/TLS/RTP/SAVPF", [108])
               |> ExSDP.add_attributes([:rtcp_mux, :sendrecv])
               |> ExSDP.add_attributes(
                 setup: :active,
                 mid: "0",
                 ice_ufrag: "someufrag",
                 ice_pwd: "somepwd",
                 fingerprint: {:sha256, @fingerprint}
               )

  @video_mline ExSDP.Media.new("video", 9, "UDP/TLS/RTP/SAVPF", [96])
               |> ExSDP.add_attribute([:rtcp_mux, :sendrecv])
               |> ExSDP.add_attributes(
                 setup: :active,
                 mid: "1",
                 ice_ufrag: "someufrag",
                 ice_pwd: "somepwd",
                 fingerprint: {:sha256, @fingerprint}
               )

  @rid_uri "urn:ietf:params:rtp-hdrext:sdes:rtp-stream-id"
  @mid_uri "urn:ietf:params:rtp-hdrext:sdes:mid"
  @twcc_uri "http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01"

  # NOTIFICATION TESTS

  # Most notifications are tested in API TESTS.
  # Here, we only put those test cases that are hard to
  # classify into other category.

  describe "negotiation needed" do
    test "is not fired when adding transceiver during negotiation" do
      {:ok, pc} = PeerConnection.start_link()
      {:ok, _tr} = PeerConnection.add_transceiver(pc, :audio)
      assert_receive {:ex_webrtc, ^pc, :negotiation_needed}
      {:ok, offer} = PeerConnection.create_offer(pc)
      :ok = PeerConnection.set_local_description(pc, offer)
      {:ok, _tr} = PeerConnection.add_transceiver(pc, :audio)

      {:ok, pc2} = PeerConnection.start_link()
      :ok = PeerConnection.set_remote_description(pc2, offer)
      {:ok, _tr} = PeerConnection.add_transceiver(pc2, :audio)

      # we do this refute_receive here, instead of after
      # adding the second audio transceiver on pc to save time
      refute_receive {:ex_webrtc, ^pc, :negotiation_needed}
      refute_receive {:ex_webrtc, ^pc2, :negotiation_needed}, 0

      {:ok, answer} = PeerConnection.create_answer(pc2)
      :ok = PeerConnection.set_local_description(pc2, answer)
      :ok = PeerConnection.set_remote_description(pc, answer)

      assert_receive {:ex_webrtc, ^pc2, :negotiation_needed}
      assert_receive {:ex_webrtc, ^pc, :negotiation_needed}
    end

    test "is not fired after successful negotiation" do
      {:ok, pc} = PeerConnection.start_link()
      {:ok, pc2} = PeerConnection.start_link()
      {:ok, _tr} = PeerConnection.add_transceiver(pc, :audio)
      assert_receive {:ex_webrtc, ^pc, :negotiation_needed}

      :ok = negotiate(pc, pc2)

      refute_receive {:ex_webrtc, ^pc2, :negotiation_needed}
      refute_receive {:ex_webrtc, ^pc, :negotiation_needed}, 0
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

  # API TESTS

  test "controlling process" do
    test_pid = self()

    spawn(fn ->
      # The first notifications are sent in PeerConnection's init callback -
      # assert they will land in the outer process.
      {:ok, pid} = PeerConnection.start_link(controlling_process: test_pid)
      # From now, all notifications should land in the inner process.
      assert :ok = PeerConnection.controlling_process(pid, self())
      :ok = PeerConnection.add_transceiver(pid, :audio)
      assert_receive {:ex_webrtc, _pid, :negotiation_needed}
    end)

    assert_receive {:ex_webrtc, _pid, {:connection_state_change, :new}}
  end

  test "get_all_running/0" do
    {:ok, pc1} = PeerConnection.start()
    {:ok, pc2} = PeerConnection.start()

    expected = MapSet.new([pc1, pc2])
    all = PeerConnection.get_all_running() |> MapSet.new()

    # Because we are running tests asynchronously,
    # we can't compare `all` and `expected` with `==`.
    assert MapSet.subset?(expected, all)

    :ok = PeerConnection.close(pc1)
    all = PeerConnection.get_all_running() |> MapSet.new()

    refute MapSet.member?(all, pc1)
    assert MapSet.member?(all, pc2)

    :ok = PeerConnection.close(pc2)
  end

  describe "get_local_description/1" do
    test "includes ICE candidates" do
      {:ok, pc} = PeerConnection.start()
      {:ok, _tr} = PeerConnection.add_transceiver(pc, :audio)
      {:ok, _tr} = PeerConnection.add_transceiver(pc, :video)
      {:ok, offer} = PeerConnection.create_offer(pc)
      :ok = PeerConnection.set_local_description(pc, offer)

      assert_receive {:ex_webrtc, _from, {:ice_candidate, cand}}
      desc = PeerConnection.get_local_description(pc)

      assert desc != nil

      sdp = ExSDP.parse!(desc.sdp)
      [audio_mline, video_mline] = sdp.media
      "candidate:" <> candidate = cand.candidate

      assert {"candidate", candidate} in ExSDP.get_attributes(audio_mline, "candidate")
      # candidates should only be present in the first m-line
      assert [] == ExSDP.get_attributes(video_mline, "candidate")
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

      rejected_mline =
        %ExSDP.Media{@audio_mline | port: 0}
        |> ExSDP.delete_attribute(:mid)
        |> ExSDP.add_attribute({:mid, "2"})

      sdp = ExSDP.add_media(ExSDP.new(), [@audio_mline, @video_mline, rejected_mline])

      [
        {[], {:error, :missing_bundle_group}},
        {[%ExSDP.Attribute.Group{semantics: "BUNDLE", mids: [0]}],
         {:error, :non_exhaustive_bundle_group}},
        {[
           %ExSDP.Attribute.Group{semantics: "BUNDLE", mids: [0, 1]},
           %ExSDP.Attribute.Group{semantics: "BUNDLE", mids: [0, 1]}
         ], {:error, :multiple_bundle_groups}},
        {[%ExSDP.Attribute.Group{semantics: "BUNDLE", mids: [0, 1]}], :ok},
        {[
           %ExSDP.Attribute.Group{semantics: "BUNDLE", mids: [0, 1]},
           %ExSDP.Attribute.Group{semantics: "LS", mids: [0, 1]}
         ], :ok}
      ]
      |> Enum.each(fn {groups, expected_result} ->
        sdp = ExSDP.add_attributes(sdp, groups) |> to_string()
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
        {{:sha256, @fingerprint}, nil, nil, :ok},
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

  describe "add_transceiver/3" do
    test "with kind" do
      {:ok, pc} = PeerConnection.start_link()

      {:ok, %RTPTransceiver{current_direction: nil, direction: :sendrecv, kind: :audio} = tr1} =
        PeerConnection.add_transceiver(pc, :audio)

      assert_receive {:ex_webrtc, ^pc, :negotiation_needed}

      {:ok, %RTPTransceiver{current_direction: nil, direction: :sendrecv, kind: :video} = tr2} =
        PeerConnection.add_transceiver(pc, :video)

      refute_receive {:ex_webrtc, ^pc, :negotiation_needed}
      assert [tr1, tr2] == PeerConnection.get_transceivers(pc)
    end

    test "with track" do
      {:ok, pc} = PeerConnection.start_link()
      track = MediaStreamTrack.new(:video)

      {:ok, %RTPTransceiver{current_direction: nil, direction: :sendrecv, kind: :video} = tr} =
        PeerConnection.add_transceiver(pc, track)

      assert_receive {:ex_webrtc, ^pc, :negotiation_needed}
      assert [tr] == PeerConnection.get_transceivers(pc)
    end

    test "with direction" do
      {:ok, pc} = PeerConnection.start_link()

      {:ok, %RTPTransceiver{current_direction: nil, direction: :recvonly, kind: :audio} = tr} =
        PeerConnection.add_transceiver(pc, :audio, direction: :recvonly)

      assert [tr] == PeerConnection.get_transceivers(pc)
    end
  end

  describe "set_transceiver_direction/3" do
    test "as offerer" do
      # When current local description is of type offer,
      # some changes in the direction does not require renegotiation
      {:ok, pc1} = PeerConnection.start_link()
      {:ok, pc2} = PeerConnection.start_link()
      {:ok, tr} = PeerConnection.add_transceiver(pc1, :audio)
      assert_receive {:ex_webrtc, ^pc1, :negotiation_needed}
      :ok = negotiate(pc1, pc2)
      :ok = PeerConnection.set_transceiver_direction(pc1, tr.id, :sendonly)
      refute_receive {:ex_webrtc, ^pc1, :negotiation_needed}
      :ok = PeerConnection.set_transceiver_direction(pc1, tr.id, :recvonly)
      assert_receive {:ex_webrtc, ^pc1, :negotiation_needed}
    end

    test "as answerer" do
      # When current local description is of type answer,
      # every change in the direction requires renegotiation.
      # Here, we check two cases: recvonly -> sendrecv, sendrecv -> recvonly
      {:ok, pc1} = PeerConnection.start_link()
      {:ok, pc2} = PeerConnection.start_link()
      {:ok, _tr} = PeerConnection.add_transceiver(pc1, :audio)
      :ok = negotiate(pc1, pc2)
      [tr] = PeerConnection.get_transceivers(pc2)
      :ok = PeerConnection.set_transceiver_direction(pc2, tr.id, :sendrecv)
      assert_receive {:ex_webrtc, ^pc2, :negotiation_needed}
      :ok = negotiate(pc1, pc2)
      :ok = PeerConnection.set_transceiver_direction(pc2, tr.id, :recvonly)
      assert_receive {:ex_webrtc, ^pc2, :negotiation_needed}
    end

    test "with invalid transceiver id" do
      {:ok, pc} = PeerConnection.start_link()
      {:ok, tr} = PeerConnection.add_transceiver(pc, :audio)

      assert {:error, :invalid_transceiver_id} ==
               PeerConnection.set_transceiver_direction(pc, tr.id + 1, :recvonly)
    end
  end

  describe "stop_transceiver/2" do
    test "before the first offer" do
      {:ok, pc1} = PeerConnection.start_link()
      {:ok, tr} = PeerConnection.add_transceiver(pc1, :audio)
      :ok = PeerConnection.stop_transceiver(pc1, tr.id)
      assert_receive {:ex_webrtc, ^pc1, {:track_ended, track_id}}
      assert tr.receiver.track.id == track_id
      {:ok, offer} = PeerConnection.create_offer(pc1)
      sdp = ExSDP.parse!(offer.sdp)
      assert sdp.media == []
    end

    test "with renegotiation" do
      {:ok, pc1} = PeerConnection.start_link()
      {:ok, pc2} = PeerConnection.start_link()
      {:ok, tr} = PeerConnection.add_transceiver(pc1, :audio)

      assert_receive {:ex_webrtc, ^pc1, :negotiation_needed}

      :ok = negotiate(pc1, pc2)

      :ok = PeerConnection.stop_transceiver(pc1, tr.id)

      assert_receive {:ex_webrtc, ^pc1, :negotiation_needed}
      assert_receive {:ex_webrtc, ^pc1, {:track_ended, track_id}}
      assert tr.receiver.track.id == track_id

      assert [
               %RTPTransceiver{
                 current_direction: :sendonly,
                 direction: :inactive,
                 stopping: true,
                 stopped: false
               }
             ] = PeerConnection.get_transceivers(pc1)

      {:ok, offer} = PeerConnection.create_offer(pc1)
      :ok = PeerConnection.set_local_description(pc1, offer)

      # nothing should change
      assert [
               %RTPTransceiver{
                 current_direction: :sendonly,
                 direction: :inactive,
                 stopping: true,
                 stopped: false
               }
             ] = PeerConnection.get_transceivers(pc1)

      # on the remote side, transceiver should be stopped
      # immediately after setting remote description
      :ok = PeerConnection.set_remote_description(pc2, offer)

      assert_receive {:ex_webrtc, ^pc2, {:track_ended, _track_id}}

      assert [
               %RTPTransceiver{
                 current_direction: nil,
                 direction: :inactive,
                 stopping: false,
                 stopped: true
               }
             ] = PeerConnection.get_transceivers(pc2)

      {:ok, answer} = PeerConnection.create_answer(pc2)
      :ok = PeerConnection.set_local_description(pc2, answer)

      assert [] == PeerConnection.get_transceivers(pc2)

      :ok = PeerConnection.set_remote_description(pc1, answer)

      assert [] == PeerConnection.get_transceivers(pc1)

      # renegotiate without changes
      {:ok, offer} = PeerConnection.create_offer(pc1)
      sdp = ExSDP.parse!(offer.sdp)
      assert Enum.count(sdp.media) == 1

      :ok = PeerConnection.set_local_description(pc1, offer)
      assert [] == PeerConnection.get_transceivers(pc1)

      # on setting remote description, a stopped transceiver
      # should be created and on setting local description
      # it should be removed
      :ok = PeerConnection.set_remote_description(pc2, offer)

      [
        %RTPTransceiver{
          current_direction: nil,
          direction: :inactive,
          stopped: true,
          stopping: false
        }
      ] = PeerConnection.get_transceivers(pc2)

      {:ok, answer} = PeerConnection.create_answer(pc2)
      sdp = ExSDP.parse!(answer.sdp)
      assert Enum.count(sdp.media) == 1

      :ok = PeerConnection.set_local_description(pc2, answer)
      assert [] == PeerConnection.get_transceivers(pc2)

      :ok = PeerConnection.set_remote_description(pc1, answer)
      assert [] == PeerConnection.get_transceivers(pc1)
    end

    test "with invalid transceiver id" do
      {:ok, pc} = PeerConnection.start_link()
      {:ok, tr} = PeerConnection.add_transceiver(pc, :audio)
      assert {:error, :invalid_transceiver_id} == PeerConnection.stop_transceiver(pc, tr.id + 1)
    end
  end

  describe "add_track/2" do
    test "with no available transceivers" do
      {:ok, pc} = PeerConnection.start_link()
      track = MediaStreamTrack.new(:audio)

      assert {:ok, sender} = PeerConnection.add_track(pc, track)
      assert_receive {:ex_webrtc, ^pc, :negotiation_needed}
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

    test "track notification" do
      {:ok, pc1} = PeerConnection.start_link()
      {:ok, pc2} = PeerConnection.start_link()
      audio_track = MediaStreamTrack.new(:audio)

      {:ok, _tr} = PeerConnection.add_track(pc1, audio_track)

      {:ok, offer} = PeerConnection.create_offer(pc1)
      :ok = PeerConnection.set_local_description(pc1, offer)
      :ok = PeerConnection.set_remote_description(pc2, offer)
      assert_receive {:ex_webrtc, ^pc2, {:track, %MediaStreamTrack{kind: :audio}}}

      # assert that re-setting offer does not emit track event again
      :ok = PeerConnection.set_remote_description(pc2, offer)
      refute_receive {:ex_webrtc, ^pc2, {:track, %MediaStreamTrack{}}}

      {:ok, answer} = PeerConnection.create_answer(pc2)
      :ok = PeerConnection.set_local_description(pc2, answer)
      :ok = PeerConnection.set_remote_description(pc1, answer)

      # assert that after renegotiation, we only notify about a new track
      video_track = MediaStreamTrack.new(:video)
      {:ok, _tr} = PeerConnection.add_track(pc1, video_track)
      :ok = negotiate(pc1, pc2)
      assert_receive {:ex_webrtc, ^pc2, {:track, %MediaStreamTrack{kind: :video}}}
      refute_receive {:ex_webrtc, ^pc2, {:track, %MediaStreamTrack{}}}
    end
  end

  describe "replace_track/3" do
    test "correct sender id" do
      {:ok, pc1} = PeerConnection.start_link()
      {:ok, pc2} = PeerConnection.start_link()
      track1 = MediaStreamTrack.new(:audio)
      track2 = MediaStreamTrack.new(:audio)

      {:ok, sender} = PeerConnection.add_track(pc1, track1)
      assert_receive {:ex_webrtc, ^pc1, :negotiation_needed}
      :ok = negotiate(pc1, pc2)

      assert :ok == PeerConnection.replace_track(pc1, sender.id, track2)
      refute_receive {:ex_webrtc, ^pc1, :negotiation_needed}
    end

    test "invalid sender id" do
      {:ok, pc} = PeerConnection.start_link()
      {:ok, sender} = PeerConnection.add_track(pc, MediaStreamTrack.new(:audio))
      assert {:error, :invalid_sender_id} = PeerConnection.replace_track(pc, sender.id + 1, nil)
    end

    test "invalid transceiver direction" do
      {:ok, pc} = PeerConnection.start_link()
      {:ok, tr} = PeerConnection.add_transceiver(pc, :audio, direction: :recvonly)

      assert {:error, :invalid_transceiver_direction} =
               PeerConnection.replace_track(pc, tr.sender.id, nil)
    end

    test "invalid track type" do
      {:ok, pc} = PeerConnection.start_link()
      track1 = MediaStreamTrack.new(:audio)
      track2 = MediaStreamTrack.new(:video)
      {:ok, sender} = PeerConnection.add_track(pc, track1)
      assert {:error, :invalid_track_type} == PeerConnection.replace_track(pc, sender.id, track2)
    end
  end

  describe "remove_track/2" do
    test "correct sender id" do
      {:ok, pc1} = PeerConnection.start_link()
      {:ok, pc2} = PeerConnection.start_link()
      track = MediaStreamTrack.new(:audio)
      {:ok, sender} = PeerConnection.add_track(pc1, track)
      assert_receive {:ex_webrtc, ^pc1, :negotiation_needed}

      :ok = negotiate(pc1, pc2)

      assert_receive {:ex_webrtc, ^pc2, {:track, pc2_track}}

      assert :ok = PeerConnection.remove_track(pc1, sender.id)
      assert_receive {:ex_webrtc, ^pc1, :negotiation_needed}

      :ok = negotiate(pc1, pc2)

      assert_receive {:ex_webrtc, ^pc2, {:track_muted, track_id}}
      assert track_id == pc2_track.id

      assert [tr1] = PeerConnection.get_transceivers(pc1)
      assert tr1.direction == :recvonly
      assert tr1.current_direction == :inactive
      assert tr1.sender.track == nil

      assert [tr2] = PeerConnection.get_transceivers(pc2)
      assert tr2.direction == :recvonly
      assert tr2.current_direction == :inactive
      assert tr2.receiver.track != nil
    end

    test "invalid sender id" do
      {:ok, pc} = PeerConnection.start_link()
      {:ok, sender} = PeerConnection.add_track(pc, MediaStreamTrack.new(:audio))
      assert {:error, :invalid_sender_id} == PeerConnection.remove_track(pc, sender.id + 1)
    end

    test "sender without track" do
      {:ok, pc1} = PeerConnection.start_link()
      {:ok, pc2} = PeerConnection.start_link()
      {:ok, tr} = PeerConnection.add_transceiver(pc1, :audio)
      assert_receive {:ex_webrtc, ^pc1, :negotiation_needed}
      :ok = negotiate(pc1, pc2)
      assert :ok == PeerConnection.remove_track(pc1, tr.sender.id)
      refute_receive {:ex_webrtc, ^pc1, :negotiation_needed}
    end
  end

  test "get_stats/2" do
    {:ok, pc1} = PeerConnection.start_link()

    # check initial state
    assert %{
             peer_connection: %{
               id: :peer_connection,
               type: :peer_connection,
               timestamp: timestamp,
               signaling_state: :stable,
               negotiation_needed: false,
               connection_state: :new
             },
             local_certificate: %{
               id: :local_certificate,
               type: :certificate,
               timestamp: timestamp,
               fingerprint_algorithm: :sha_256
             },
             remote_certificate: %{
               id: :remote_certificate,
               type: :certificate,
               timestamp: timestamp,
               fingerprint: nil,
               fingerprint_algorithm: nil,
               base64_certificate: nil
             },
             transport: %{
               id: :transport,
               type: :transport,
               timestamp: timestamp,
               ice_state: :new,
               ice_gathering_state: :new,
               dtls_state: :new,
               bytes_sent: 0,
               bytes_received: 0,
               packets_sent: 0,
               packets_received: 0
             }
           } = stats = PeerConnection.get_stats(pc1)

    assert is_binary(stats.local_certificate.fingerprint)
    assert is_binary(stats.local_certificate.base64_certificate)

    assert stats.transport.ice_role in [:controlling, :controlled]
    assert is_binary(stats.transport.ice_local_ufrag)

    groups = Enum.group_by(Map.values(stats), & &1.type)

    assert Map.get(groups, :inbound_rtp) == nil
    assert Map.get(groups, :outbound_rtp) == nil
    assert Map.get(groups, :local_candidate) == nil
    assert Map.get(groups, :remote_candidate) == nil

    # negotiate tracks
    {:ok, pc2} = PeerConnection.start_link()

    track1 = MediaStreamTrack.new(:audio)
    track2 = MediaStreamTrack.new(:audio)

    {:ok, _sender} = PeerConnection.add_track(pc1, track1)
    {:ok, _sender} = PeerConnection.add_track(pc2, track2)

    :ok = negotiate(pc1, pc2)
    test_send_data(pc1, pc2, track1, track2)

    stats1 = PeerConnection.get_stats(pc1)
    stats2 = PeerConnection.get_stats(pc2)

    assert %{
             peer_connection: %{
               signaling_state: :stable,
               negotiation_needed: false,
               connection_state: :connected
             },
             remote_certificate: %{
               fingerprint_algorithm: :sha_256
             },
             transport: %{
               ice_state: :connected,
               ice_gathering_state: :complete,
               dtls_state: :connected
             }
           } = stats1

    assert stats1.transport.bytes_sent > 0
    assert stats1.transport.bytes_received > 0
    assert stats1.transport.packets_sent > 0
    assert stats1.transport.packets_received > 0

    assert is_binary(stats1.remote_certificate.fingerprint)
    assert is_binary(stats1.remote_certificate.base64_certificate)

    groups = Enum.group_by(Map.values(stats1), & &1.type)

    assert length(Map.get(groups, :inbound_rtp, [])) == 1
    assert length(Map.get(groups, :outbound_rtp, [])) == 1
    assert length(Map.get(groups, :local_candidate, [])) > 0
    assert length(Map.get(groups, :remote_candidate, [])) > 0

    assert %{
             peer_connection: %{
               signaling_state: :stable,
               negotiation_needed: false,
               connection_state: :connected
             },
             remote_certificate: %{
               fingerprint_algorithm: :sha_256
             },
             transport: %{
               ice_state: :connected,
               ice_gathering_state: :complete,
               dtls_state: :connected
             }
           } = stats2

    assert stats2.transport.bytes_sent > 0
    assert stats2.transport.bytes_received > 0
    assert stats2.transport.packets_sent > 0
    assert stats2.transport.packets_received > 0

    assert is_binary(stats2.remote_certificate.fingerprint)
    assert is_binary(stats2.remote_certificate.base64_certificate)

    groups = Enum.group_by(Map.values(stats2), & &1.type)

    assert length(Map.get(groups, :inbound_rtp, [])) == 1
    assert length(Map.get(groups, :outbound_rtp, [])) == 1
    assert length(Map.get(groups, :local_candidate, [])) > 0
    assert length(Map.get(groups, :remote_candidate, [])) > 0
  end

  test "close/1" do
    {:ok, pc} = PeerConnection.start()
    {:links, links} = Process.info(pc, :links)
    assert :ok == PeerConnection.close(pc)
    assert false == Process.alive?(pc)

    Enum.each(links, fn link ->
      assert false == Process.alive?(link) or
               Process.info(link)[:registered_name] == ExWebRTC.Registry.PIDPartition0
    end)

    {:ok, pc} = PeerConnection.start()
    {:links, links} = Process.info(pc, :links)
    assert true == Process.exit(pc, :shutdown)
    assert false == Process.alive?(pc)

    Enum.each(links, fn link ->
      assert false == Process.alive?(link) or
               Process.info(link)[:registered_name] == ExWebRTC.Registry.PIDPartition0
    end)
  end

  # MISC TESTS

  describe "send data in both directions on a single transceiver" do
    test "using one negotiation" do
      {:ok, pc1} = PeerConnection.start_link()
      {:ok, pc2} = PeerConnection.start_link()

      track1 = MediaStreamTrack.new(:audio)
      track2 = MediaStreamTrack.new(:audio)

      {:ok, _sender} = PeerConnection.add_track(pc1, track1)
      {:ok, offer} = PeerConnection.create_offer(pc1)
      :ok = PeerConnection.set_local_description(pc1, offer)
      :ok = PeerConnection.set_remote_description(pc2, offer)

      [tr] = PeerConnection.get_transceivers(pc2)
      :ok = PeerConnection.set_transceiver_direction(pc2, tr.id, :sendrecv)
      :ok = PeerConnection.replace_track(pc2, tr.sender.id, track2)

      {:ok, answer} = PeerConnection.create_answer(pc2)
      :ok = PeerConnection.set_local_description(pc2, answer)
      :ok = PeerConnection.set_remote_description(pc1, answer)

      test_send_data(pc1, pc2, track1, track2)
    end

    test "using one negotiation, with tracks added beforehand" do
      {:ok, pc1} = PeerConnection.start_link()
      {:ok, pc2} = PeerConnection.start_link()

      track1 = MediaStreamTrack.new(:audio)
      track2 = MediaStreamTrack.new(:audio)

      {:ok, _sender} = PeerConnection.add_track(pc1, track1)
      {:ok, _sender} = PeerConnection.add_track(pc2, track2)

      :ok = negotiate(pc1, pc2)

      test_send_data(pc1, pc2, track1, track2)
    end

    test "using renegotiation" do
      # setup track pc1 -> pc2
      {:ok, pc1} = PeerConnection.start_link()
      {:ok, pc2} = PeerConnection.start_link()
      track1 = MediaStreamTrack.new(:audio)
      {:ok, _sender} = PeerConnection.add_track(pc1, track1)
      :ok = negotiate(pc1, pc2)
      # setup track pc2 -> pc1
      track2 = MediaStreamTrack.new(:audio)
      {:ok, _sender} = PeerConnection.add_track(pc2, track2)

      :ok = negotiate(pc2, pc1)

      test_send_data(pc1, pc2, track1, track2)
    end

    test "using simulcast" do
      {:ok, pc} = PeerConnection.start_link()
      track = MediaStreamTrack.new(:video)
      {:ok, _sender} = PeerConnection.add_track(pc, track)
      {:ok, offer} = PeerConnection.create_offer(pc)

      # ExWebRTC does not support outbound Simulcast
      # so this needs to be a little hacky
      rids = ["h", "l", "m"]
      sdp = ExSDP.parse!(offer.sdp)
      [video] = sdp.media

      video =
        Enum.reduce(rids, video, fn rid, video ->
          attr = %ExSDP.Attribute.RID{id: rid, direction: :send}
          ExSDP.add_attribute(video, attr)
        end)

      video = ExSDP.add_attribute(video, %ExSDP.Attribute.Simulcast{send: rids})
      sdp = %ExSDP{sdp | media: [video]}
      offer = %ExWebRTC.SessionDescription{sdp: to_string(sdp), type: :offer}

      {:ok, pc2} = PeerConnection.start_link()
      :ok = PeerConnection.set_remote_description(pc2, offer)
      {:ok, answer} = PeerConnection.create_answer(pc2)
      :ok = PeerConnection.set_local_description(pc2, answer)
      [transceiver] = PeerConnection.get_transceivers(pc2)

      assert %ExSDP.Attribute.Extmap{id: rid_id} =
               Enum.find(transceiver.rtp_hdr_exts, &(&1.uri == @rid_uri))

      assert %ExSDP.Attribute.Extmap{id: mid_id} =
               Enum.find(transceiver.rtp_hdr_exts, &(&1.uri == @mid_uri))

      assert %ExSDP.Attribute.Extmap{id: twcc_id} =
               Enum.find(transceiver.rtp_hdr_exts, &(&1.uri == @twcc_uri))

      assert_receive {:ex_webrtc, ^pc2, {:track, %MediaStreamTrack{kind: :video, id: id2}}}

      rids
      |> Enum.with_index()
      |> Enum.each(fn {rid, idx} ->
        rid_ext = %ExRTP.Packet.Extension{data: rid, id: rid_id}
        mid_ext = %ExRTP.Packet.Extension{data: transceiver.mid, id: mid_id}
        twcc_ext = %ExRTP.Packet.Extension{data: <<idx::16>>, id: twcc_id}
        payload = <<idx, idx, idx>>

        ExRTP.Packet.new(payload,
          payload_type: transceiver.receiver.codec.payload_type,
          sequence_number: 100_000 * idx,
          timestamp: 100_000 * idx,
          ssrc: 100 * idx
        )
        |> ExRTP.Packet.add_extension(rid_ext)
        |> ExRTP.Packet.add_extension(mid_ext)
        |> ExRTP.Packet.add_extension(twcc_ext)
        |> ExRTP.Packet.encode()
        |> then(&send(pc2, {:dtls_transport, :fake_pid, {:rtp, &1}}))

        assert_receive {:ex_webrtc, ^pc2, {:rtp, ^id2, ^rid, %ExRTP.Packet{payload: ^payload}}}
      end)
    end
  end

  defp test_send_data(pc1, pc2, track1, track2) do
    # exchange ICE candidates
    assert_receive {:ex_webrtc, ^pc1, {:ice_candidate, candidate}}
    :ok = PeerConnection.add_ice_candidate(pc2, candidate)
    assert_receive {:ex_webrtc, ^pc2, {:ice_candidate, candidate}}
    :ok = PeerConnection.add_ice_candidate(pc1, candidate)

    # wait to establish connection
    assert_receive {:ex_webrtc, ^pc1, {:connection_state_change, :connected}}, 1000
    assert_receive {:ex_webrtc, ^pc2, {:connection_state_change, :connected}}, 1000

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
    packet = ExRTP.Packet.new(payload)
    :ok = PeerConnection.send_rtp(pc1, track1.id, packet)

    assert_receive {:ex_webrtc, ^pc2, {:rtp, ^id2, nil, %ExRTP.Packet{payload: ^payload}}}

    payload = <<7, 8, 9>>
    packet = ExRTP.Packet.new(payload)
    :ok = PeerConnection.send_rtp(pc2, track2.id, packet)

    assert_receive {:ex_webrtc, ^pc1, {:rtp, ^id1, nil, %ExRTP.Packet{payload: ^payload}}}
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

  test "reject incoming track" do
    {:ok, pc1} = PeerConnection.start_link()
    {:ok, pc2} = PeerConnection.start_link()
    {:ok, _tr} = PeerConnection.add_transceiver(pc1, :audio)
    {:ok, offer} = PeerConnection.create_offer(pc1)
    :ok = PeerConnection.set_local_description(pc1, offer)

    :ok = PeerConnection.set_remote_description(pc2, offer)
    assert_receive {:ex_webrtc, ^pc2, {:track, track}}
    [tr] = PeerConnection.get_transceivers(pc2)
    :ok = PeerConnection.set_transceiver_direction(pc2, tr.id, :inactive)
    {:ok, answer} = PeerConnection.create_answer(pc2)
    :ok = PeerConnection.set_local_description(pc2, answer)

    :ok = PeerConnection.set_remote_description(pc1, answer)

    assert_receive {:ex_webrtc, ^pc2, {:track_muted, track_id}}
    assert track.id == track_id

    assert [%RTPTransceiver{direction: :sendrecv, current_direction: :inactive}] =
             PeerConnection.get_transceivers(pc1)

    assert [%RTPTransceiver{direction: :inactive, current_direction: :inactive}] =
             PeerConnection.get_transceivers(pc2)
  end

  test "no supported codecs" do
    {:ok, pc1} =
      PeerConnection.start_link(
        video_codecs: [
          %RTPCodecParameters{
            payload_type: 96,
            mime_type: "video/VP8",
            clock_rate: 90_000
          }
        ]
      )

    {:ok, pc2} =
      PeerConnection.start_link(
        video_codecs: [
          %RTPCodecParameters{
            payload_type: 45,
            mime_type: "video/AV1",
            clock_rate: 90_000
          }
        ]
      )

    {:ok, _tr} = PeerConnection.add_transceiver(pc1, :video)

    assert_receive {:ex_webrtc, ^pc1, :negotiation_needed}

    :ok = negotiate(pc1, pc2)

    assert [] == PeerConnection.get_transceivers(pc1)
    assert [] == PeerConnection.get_transceivers(pc2)

    assert_receive {:ex_webrtc, ^pc1, {:track_ended, _track_id}}
    assert_receive {:ex_webrtc, ^pc2, {:track, pc2_track}}
    pc2_track_id = pc2_track.id
    assert_receive {:ex_webrtc, ^pc2, {:track_muted, ^pc2_track_id}}
    assert_receive {:ex_webrtc, ^pc2, {:track_ended, ^pc2_track_id}}

    # make sure there was only one negotiation_needed fired
    refute_receive {:ex_webrtc, ^pc1, :negotiation_needed}
    refute_receive {:ex_webrtc, ^pc2, :negotiation_needed}, 0
  end
end
