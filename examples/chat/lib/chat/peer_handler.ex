defmodule Chat.PeerHandler do
  require Logger

  alias ExWebRTC.{
    DataChannel,
    ICECandidate,
    PeerConnection,
    SessionDescription
  }

  @behaviour WebSock

  @ice_servers [
    %{urls: "stun:stun.l.google.com:19302"}
  ]

  @impl true
  def init(_) do
    {:ok, pc} = PeerConnection.start_link(ice_servers: @ice_servers)
    {:ok, _} = Registry.register(Chat.PubSub, "chat", [])

    state = %{
      peer_connection: pc,
      channel_ref: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_in({msg, [opcode: :text]}, state) do
    msg
    |> Jason.decode!()
    |> handle_ws_msg(state)
  end

  @impl true
  def handle_info({:ex_webrtc, _from, msg}, state) do
    handle_webrtc_msg(msg, state)
  end

  @impl true
  def handle_info({:chat_msg, msg}, state) do
    :ok = PeerConnection.send_data(state.peer_connection, state.channel_ref, msg)
    {:ok, state}
  end

  @impl true
  def terminate(reason, _state) do
    Logger.warning("WebSocket connection was terminated, reason: #{inspect(reason)}")
  end

  defp handle_ws_msg(%{"type" => "offer", "data" => data}, state) do
    Logger.info("Received SDP offer:\n#{data["sdp"]}")

    offer = SessionDescription.from_json(data)
    :ok = PeerConnection.set_remote_description(state.peer_connection, offer)

    {:ok, answer} = PeerConnection.create_answer(state.peer_connection)
    :ok = PeerConnection.set_local_description(state.peer_connection, answer)

    answer_json = SessionDescription.to_json(answer)

    msg =
      %{"type" => "answer", "data" => answer_json}
      |> Jason.encode!()

    Logger.info("Sent SDP answer:\n#{answer_json["sdp"]}")

    {:push, {:text, msg}, state}
  end

  defp handle_ws_msg(%{"type" => "ice", "data" => data}, state) do
    Logger.info("Received ICE candidate: #{data["candidate"]}")

    candidate = ICECandidate.from_json(data)
    :ok = PeerConnection.add_ice_candidate(state.peer_connection, candidate)
    {:ok, state}
  end

  defp handle_webrtc_msg({:ice_candidate, candidate}, state) do
    candidate_json = ICECandidate.to_json(candidate)

    msg =
      %{"type" => "ice", "data" => candidate_json}
      |> Jason.encode!()

    Logger.info("Sent ICE candidate: #{candidate_json["candidate"]}")

    {:push, {:text, msg}, state}
  end

  defp handle_webrtc_msg({:data_channel, %DataChannel{ref: ref}}, state) do
    state = %{state | channel_ref: ref}
    {:ok, state}
  end

  defp handle_webrtc_msg({:data, ref, data}, %{channel_ref: ref} = state) do
    Registry.dispatch(Chat.PubSub, "chat", fn entries ->
      for {pid, _} <- entries, do: send(pid, {:chat_msg, data})
    end)

    {:ok, state}
  end

  defp handle_webrtc_msg(_msg, state), do: {:ok, state}
end
