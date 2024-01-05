Mix.install([{:gun, "~> 2.0.1"}, {:ex_webrtc, path: "../.."}, {:jason, "~> 1.4.0"}])

require Logger
Logger.configure(level: :info)

defmodule Peer do
  use GenServer

  require Logger

  alias ExWebRTC.{
    IceCandidate,
    MediaStreamTrack,
    PeerConnection,
    SessionDescription,
    RTPCodecParameters
  }

  alias ExWebRTC.RTP.{OpusDepayloader, VP8Depayloader}
  alias ExWebRTC.Media.{IVF, Ogg}

  @ice_servers [
    %{urls: "stun:stun.l.google.com:19302"}
  ]

  def start_link() do
    GenServer.start_link(__MODULE__, nil)
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

        {:ok, pc} =
          PeerConnection.start_link(
            ice_servers: @ice_servers,
            video_codecs: [
              %RTPCodecParameters{
                payload_type: 96,
                mime_type: "video/VP8",
                clock_rate: 90_000
              }
            ]
          )

        {:ok,
         %{
           conn: conn,
           stream: stream,
           peer_connection: pc,
           video_track_id: nil,
           audio_track_id: nil,
           vp8_depayloader: nil,
           ivf_writer: nil,
           ogg_writer: nil,
           frames_cnt: 0
         }}

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
  end

  defp handle_ws_message(%{"type" => "ice", "data" => data}, state) do
    Logger.info("Received remote ICE candidate: #{inspect(data)}")

    candidate = %IceCandidate{
      candidate: data["candidate"],
      sdp_mid: data["sdpMid"],
      sdp_m_line_index: data["sdpMLineIndex"],
      username_fragment: data["usernameFragment"]
    }

    :ok = PeerConnection.add_ice_candidate(state.peer_connection, candidate)
  end

  defp handle_ws_message(%{"type" => "peer_left"}, state) do
    # in real scenario you should probably close the PeerConnection explicitly
    Ogg.Writer.close(state.ogg_writer)
    IVF.Writer.close(state.ivf_writer)
    Logger.info("Remote peer left. Closing files and exiting.")
    exit(:normal)
  end

  defp handle_ws_message(msg, _state) do
    Logger.info("Received unexpected message: #{inspect(msg)}")
  end

  defp handle_webrtc_message({:ice_candidate, candidate}, state) do
    candidate = %{
      "candidate" => candidate.candidate,
      "sdpMid" => candidate.sdp_mid,
      "sdpMLineIndex" => candidate.sdp_m_line_index,
      "usernameFragment" => candidate.username_fragment
    }

    msg = %{"type" => "ice", "data" => candidate}
    :gun.ws_send(state.conn, state.stream, {:text, Jason.encode!(msg)})
    state
  end

  defp handle_webrtc_message({:track, %MediaStreamTrack{kind: :video, id: id}}, state) do
    <<fourcc::little-32>> = "VP80"

    # Width, height and FPS (timebase_denum/num)
    # are the same as we set in video constraints
    # on the frontend side (in getUserMedia).
    # However, keep in mind they can change in time
    # so this is best effort saving.
    # `num_frames` is set to 900 and it will be updated
    # every `num_frames` by `num_frames`.
    {:ok, ivf_writer} =
      IVF.Writer.open("./video.ivf",
        fourcc: fourcc,
        height: 640,
        width: 480,
        num_frames: 900,
        timebase_denum: 15,
        timebase_num: 1
      )

    %{state | vp8_depayloader: VP8Depayloader.new(), ivf_writer: ivf_writer, video_track_id: id}
  end

  defp handle_webrtc_message({:track, %MediaStreamTrack{kind: :audio, id: id}}, state) do
    # by default uses 1 mono channel and 48k clock rate
    {:ok, ogg_writer} = Ogg.Writer.open("./audio.ogg")
    %{state | ogg_writer: ogg_writer, audio_track_id: id}
  end

  defp handle_webrtc_message({:rtp, id, packet}, %{video_track_id: id} = state) do
    case VP8Depayloader.write(state.vp8_depayloader, packet) do
      {:ok, vp8_depayloader} ->
        %{state | vp8_depayloader: vp8_depayloader}

      {:ok, vp8_frame, vp8_depayloader} ->
        frame = %IVF.Frame{timestamp: state.frames_cnt, data: vp8_frame}
        {:ok, ivf_writer} = IVF.Writer.write_frame(state.ivf_writer, frame)

        %{
          state
          | vp8_depayloader: vp8_depayloader,
            ivf_writer: ivf_writer,
            frames_cnt: state.frames_cnt + 1
        }
    end
  end

  defp handle_webrtc_message({:rtp, id, packet}, %{audio_track_id: id} = state) do
    opus_packet = OpusDepayloader.depayload(packet)
    {:ok, ogg_writer} = Ogg.Writer.write_packet(state.ogg_writer, opus_packet)
    %{state | ogg_writer: ogg_writer}
  end

  defp handle_webrtc_message(msg, state) do
    Logger.warning("Received unknown ex_webrtc message: #{inspect(msg)}")
    state
  end
end

{:ok, pid} = Peer.start_link()
ref = Process.monitor(pid)

receive do
  {:DOWN, ^ref, _, _, _} ->
    Logger.info("Peer process closed. Exiting")

  other ->
    Logger.warning("Unexpected msg. Exiting. Msg: #{inspect(other)}")
end
