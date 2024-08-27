defmodule ExWebRTC.Support.TestUtils do
  @moduledoc false

  alias ExWebRTC.PeerConnection

  @spec negotiate(PeerConnection.peer_connection(), PeerConnection.peer_connection()) :: :ok
  def negotiate(pc1, pc2) do
    {:ok, offer} = PeerConnection.create_offer(pc1)
    :ok = PeerConnection.set_local_description(pc1, offer)
    :ok = PeerConnection.set_remote_description(pc2, offer)
    {:ok, answer} = PeerConnection.create_answer(pc2)
    :ok = PeerConnection.set_local_description(pc2, answer)
    :ok = PeerConnection.set_remote_description(pc1, answer)
    :ok
  end

  @spec connect(PeerConnection.peer_connection(), PeerConnection.peer_connection()) :: :ok
  def connect(pc1, pc2) do
    # exchange ICE candidates
    for {pc1, pc2} <- [{pc1, pc2}, {pc2, pc1}] do
      receive do
        {:ex_webrtc, ^pc1, {:ice_candidate, candidate}} ->
          :ok = PeerConnection.add_ice_candidate(pc2, candidate)
      after
        2000 -> raise "Unable to connect"
      end
    end

    for pc <- [pc1, pc2] do
      receive do
        {:ex_webrtc, ^pc, {:connection_state_change, :connected}} -> :ok
      after
        2000 -> raise "Unable to connect"
      end
    end

    :ok
  end
end
