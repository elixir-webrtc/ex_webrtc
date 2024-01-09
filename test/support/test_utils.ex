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
end
