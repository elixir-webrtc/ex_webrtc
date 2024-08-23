defmodule ExWebRTC.Support.TestUtils do
  @moduledoc false

  import ExUnit.Assertions

  alias ExWebRTC.PeerConnection

  @spec negotiate(PeerConnection.peer_connection(), PeerConnection.peer_connection()) :: :ok
  def negotiate(pc1, pc2) do
    assert {:ok, offer} = PeerConnection.create_offer(pc1)
    assert :ok = PeerConnection.set_local_description(pc1, offer)
    assert :ok = PeerConnection.set_remote_description(pc2, offer)
    assert {:ok, answer} = PeerConnection.create_answer(pc2)
    assert :ok = PeerConnection.set_local_description(pc2, answer)
    assert :ok = PeerConnection.set_remote_description(pc1, answer)
    :ok
  end

  @spec connect(PeerConnection.peer_connection(), PeerConnection.peer_connection()) :: :ok
  def connect(pc1, pc2) do
    # exchange ICE candidates
    assert_receive {:ex_webrtc, ^pc1, {:ice_candidate, candidate}}
    :ok = PeerConnection.add_ice_candidate(pc2, candidate)
    assert_receive {:ex_webrtc, ^pc2, {:ice_candidate, candidate}}
    :ok = PeerConnection.add_ice_candidate(pc1, candidate)

    # wait to establish connection
    assert_receive {:ex_webrtc, ^pc1, {:connection_state_change, :connected}}
    assert_receive {:ex_webrtc, ^pc2, {:connection_state_change, :connected}}

    :ok
  end
end
