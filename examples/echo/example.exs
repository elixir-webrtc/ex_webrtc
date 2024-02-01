Mix.install([{:gun, "~> 2.0.1"}, {:ex_webrtc, path: "../.."}, {:jason, "~> 1.4.0"}])

require Logger
Logger.configure(level: :info)

defmodule Peer do
  use GenServer

  require Logger

  alias ExWebRTC.{
    ICECandidate,
    PeerConnection,
    MediaStreamTrack,
    SessionDescription
  }

  @ice_servers [
    %{urls: "stun:stun.l.google.com:19302"}
  ]

  def start() do
    GenServer.start(__MODULE__, nil)
  end

  @impl true
  def init(_) do
    {:ok, conn} = :gun.open({127, 0, 0, 1}, 4000)
    {:ok, _protocol} = :gun.await_up(conn)
    :gun.ws_upgrade(conn, "/websocket")

    receive do
      {:gun_upgrade, ^conn, stream, _, _} ->
        Logger.info("Connected to the signalling server")
        Process.send_after(self(), :ws_ping, 1000)

        {:ok, pc} = PeerConnection.start_link(ice_servers: @ice_servers)

        state = %{
          conn: conn,
          stream: stream,
          peer_connection: pc,
          out_audio_track_id: nil,
          out_video_track_id: nil,
          in_audio_track_id: nil,
          in_video_track_id: nil
        }

        {:ok, state}

      other ->
        Logger.error("Couldn't connect to the signalling server: #{inspect(other)}")
        exit(:error)
    end
  end

  @impl true
  def handle_info({:gun_down, _, :ws, :closed, _}, state) do
    Logger.info("Server closed ws connection. Exiting")
    {:stop, :normal, state}
  end

  @impl true
  def handle_info(:ws_ping, state) do
    Process.send_after(self(), :ws_ping, 1000)
    :gun.ws_send(state.conn, state.stream, :ping)
    {:noreply, state}
  end

  @impl true
  def handle_info({:gun_ws, _, _, {:text, msg}}, state) do
    state =
      msg
      |> Jason.decode!()
      |> handle_ws_message(state)

    {:noreply, state}
  end

  @impl true
  def handle_info({:gun_ws, _, _, {:close, code}}, _state) do
    Logger.info("Signalling connection closed with code: #{code}. Exiting")
    exit(:ws_down)
  end

  @impl true
  def handle_info({:ex_webrtc, _pid, msg}, state) do
    state = handle_webrtc_message(msg, state)
    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.warning("Received unknown msg: #{inspect(msg)}")
    {:noreply, state}
  end

  defp handle_ws_message(%{"type" => "offer", "sdp" => sdp}, %{peer_connection: pc} = state) do
    offer = %SessionDescription{type: :offer, sdp: sdp}
    Logger.info("Received SDP offer: #{inspect(offer.sdp)}")
    :ok = PeerConnection.set_remote_description(pc, offer)
    {:ok, answer} = PeerConnection.create_answer(pc)
    :ok = PeerConnection.set_local_description(pc, answer)
    Logger.info("Sent SDP answer: #{inspect(answer.sdp)}")
    msg = %{"type" => "answer", "sdp" => answer.sdp}
    :gun.ws_send(state.conn, state.stream, {:text, Jason.encode!(msg)})

    video_track = MediaStreamTrack.new(:video)
    audio_track = MediaStreamTrack.new(:audio)
    {:ok, _} = PeerConnection.add_track(pc, video_track)
    {:ok, _} = PeerConnection.add_track(pc, audio_track)
    {:ok, offer} = PeerConnection.create_offer(pc)
    :ok = PeerConnection.set_local_description(pc, offer)
    Logger.info("Sent SDP offer: #{inspect(offer.sdp)}")
    msg = %{"type" => "offer", "sdp" => offer.sdp}
    :gun.ws_send(state.conn, state.stream, {:text, Jason.encode!(msg)})

    %{state | out_audio_track_id: audio_track.id, out_video_track_id: video_track.id}
  end

  defp handle_ws_message(%{"type" => "answer", "sdp" => sdp}, state) do
    answer = %SessionDescription{type: :answer, sdp: sdp}
    Logger.info("Received SDP answer: #{inspect(answer.sdp)}")
    :ok = PeerConnection.set_remote_description(state.peer_connection, answer)
    state
  end

  defp handle_ws_message(%{"type" => "ice", "data" => data}, state) do
    Logger.info("Received remote ICE candidate: #{inspect(data)}")
    candidate = ICECandidate.from_json(data)
    :ok = PeerConnection.add_ice_candidate(state.peer_connection, candidate)
    state
  end

  defp handle_ws_message(msg, state) do
    Logger.info("Received unexpected message: #{inspect(msg)}")
    state
  end

  defp handle_webrtc_message({:ice_candidate, candidate}, state) do
    msg = %{"type" => "ice", "data" => ICECandidate.to_json(candidate))
    :gun.ws_send(state.conn, state.stream, {:text, Jason.encode!(msg)})
    state
  end

  defp handle_webrtc_message({:track, track}, state) do
    %MediaStreamTrack{kind: kind, id: id} = track

    case kind do
      :audio -> %{state | in_audio_track_id: id}
      :video -> %{state | in_video_track_id: id}
    end
  end

  defp handle_webrtc_message({:rtp, id, packet}, %{in_audio_track_id: id} = state) do
    PeerConnection.send_rtp(state.peer_connection, state.out_audio_track_id, packet)
    state
  end

  defp handle_webrtc_message({:rtp, id, packet}, %{in_video_track_id: id} = state) do
    PeerConnection.send_rtp(state.peer_connection, state.out_video_track_id, packet)
    state
  end

  defp handle_webrtc_message({:rtcp, packet}, state) do
    Logger.info("Received RCTP: #{inspect(packet)}")
    state
  end

  defp handle_webrtc_message(msg, state) do
    Logger.warning("Received other ex_webrtc message: #{inspect(msg)}")
    state
  end
end

{:ok, pid} = Peer.start()
ref = Process.monitor(pid)

receive do
  {:DOWN, ^ref, _, _, reason} ->
    Logger.info("Peer process closed, reason: #{inspect(reason)}. Exiting")

  other ->
    Logger.warning("Unexpected msg. Exiting. Msg: #{inspect(other)}")
end
