defmodule ExWebRTC.RenegotiationTest do
  use ExUnit.Case, async: true

  import ExWebRTC.Support.TestUtils

  alias ExWebRTC.{PeerConnection, RTPTransceiver}

  test "stop two and add one with different kind" do
    # 1. add audio and video transceiver
    # 2. stop both
    # 3. add video
    # 4. the output should be video (9), video (0)
    {:ok, pc1} = PeerConnection.start_link()
    {:ok, pc2} = PeerConnection.start_link()

    {:ok, pc1_tr1} = PeerConnection.add_transceiver(pc1, :audio)
    {:ok, pc1_tr2} = PeerConnection.add_transceiver(pc1, :video)

    :ok = negotiate(pc1, pc2)

    :ok = PeerConnection.stop_transceiver(pc1, pc1_tr1.id)
    :ok = PeerConnection.stop_transceiver(pc1, pc1_tr2.id)

    :ok = negotiate(pc1, pc2)

    assert [] = PeerConnection.get_transceivers(pc1)
    assert [] = PeerConnection.get_transceivers(pc2)

    {:ok, pc1_tr3} = PeerConnection.add_transceiver(pc1, :video)

    # should reuse the first mline even though it's of kind audio
    {:ok, offer} = PeerConnection.create_offer(pc1)
    sdp = ExSDP.parse!(offer.sdp)
    assert [%{type: :video, port: 9}, %{type: :video, port: 0}] = sdp.media

    assert :ok = continue_negotiation(pc1, pc2, offer)

    pc1_tr3_id = pc1_tr3.id

    [
      %RTPTransceiver{
        id: ^pc1_tr3_id,
        kind: :video,
        current_direction: :sendonly,
        direction: :sendrecv,
        stopping: false,
        stopped: false
      }
    ] = PeerConnection.get_transceivers(pc1)

    [
      %RTPTransceiver{
        kind: :video,
        current_direction: :recvonly,
        direction: :recvonly,
        stopped: false,
        stopping: false
      }
    ] = PeerConnection.get_transceivers(pc2)
  end

  test "stop one and add two with switched kinds" do
    # 1. add audio and video transceiver
    # 2. stop audio transceiver
    # 3. add video and audio
    # 4. the output should be video (9), video (9), audio (9)
    {:ok, pc1} = PeerConnection.start_link()
    {:ok, pc2} = PeerConnection.start_link()

    {:ok, pc1_tr1} = PeerConnection.add_transceiver(pc1, :audio)
    {:ok, pc1_tr2} = PeerConnection.add_transceiver(pc1, :video)

    :ok = negotiate(pc1, pc2)

    [pc2_tr1, pc2_tr2] = PeerConnection.get_transceivers(pc2)

    :ok = PeerConnection.stop_transceiver(pc1, pc1_tr1.id)

    :ok = negotiate(pc1, pc2)

    {:ok, pc1_tr3} = PeerConnection.add_transceiver(pc1, :video)
    {:ok, pc1_tr4} = PeerConnection.add_transceiver(pc1, :audio)

    {:ok, offer} = PeerConnection.create_offer(pc1)
    sdp = ExSDP.parse!(offer.sdp)

    assert [%{type: :video, port: 9}, %{type: :video, port: 9}, %{type: :audio, port: 9}] =
             sdp.media

    assert :ok = continue_negotiation(pc1, pc2, offer)

    pc1_tr2_id = pc1_tr2.id
    pc1_tr3_id = pc1_tr3.id
    pc1_tr4_id = pc1_tr4.id

    [
      %RTPTransceiver{
        id: ^pc1_tr2_id,
        kind: :video,
        current_direction: :sendonly,
        direction: :sendrecv,
        stopping: false,
        stopped: false
      },
      %RTPTransceiver{
        id: ^pc1_tr3_id,
        kind: :video,
        current_direction: :sendonly,
        direction: :sendrecv,
        stopping: false,
        stopped: false
      },
      %RTPTransceiver{
        id: ^pc1_tr4_id,
        kind: :audio,
        current_direction: :sendonly,
        direction: :sendrecv,
        stopping: false,
        stopped: false
      }
    ] = PeerConnection.get_transceivers(pc1)

    pc2_tr2_id = pc2_tr2.id

    [
      %RTPTransceiver{
        id: ^pc2_tr2_id,
        kind: :video,
        current_direction: :recvonly,
        direction: :recvonly,
        stopped: false,
        stopping: false
      },
      %RTPTransceiver{
        kind: :video,
        current_direction: :recvonly,
        direction: :recvonly,
        stopped: false,
        stopping: false
      } = tr2,
      %RTPTransceiver{
        kind: :audio,
        current_direction: :recvonly,
        direction: :recvonly,
        stopped: false,
        stopping: false
      } = tr3
    ] = PeerConnection.get_transceivers(pc2)

    # make sure we didn't reuse stopped transceiver
    assert tr2.id != pc2_tr1.id
    assert tr3.id != pc2_tr1.id
  end

  defp continue_negotiation(pc1, pc2, offer) do
    :ok = PeerConnection.set_local_description(pc1, offer)
    :ok = PeerConnection.set_remote_description(pc2, offer)
    {:ok, answer} = PeerConnection.create_answer(pc2)
    :ok = PeerConnection.set_local_description(pc2, answer)
    :ok = PeerConnection.set_remote_description(pc1, answer)
    :ok
  end
end
