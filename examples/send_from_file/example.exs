Mix.install([{:gun, "~> 2.0.1"}, {:ex_webrtc, path: "../.."}, {:jason, "~> 1.4.0"}])

require Logger
Logger.configure(level: :info)

defmodule Peer do
  use GenServer

  require Logger

  import Bitwise

  alias ExWebRTC.{
    IceCandidate,
    MediaStreamTrack,
    Media.IVFReader,
    Media.OggReader,
    PeerConnection,
    RTPCodecParameters,
    RTP.VP8Payloader,
    RTPTransceiver,
    SessionDescription
  }

  @max_rtp_timestamp (1 <<< 32) - 1

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
            audio_codecs: [
              %RTPCodecParameters{
                payload_type: 111,
                mime_type: "audio/opus",
                clock_rate: 48_000,
                channels: 2,
                sdp_fmtp_line: %ExSDP.Attribute.FMTP{pt: 111, minptime: 10, useinbandfec: true}
              }
            ],
            video_codecs: [
              %RTPCodecParameters{
                payload_type: 96,
                mime_type: "video/VP8",
                clock_rate: 90_000,
                channels: nil,
                sdp_fmtp_line: nil,
                rtcp_fbs: []
              }
            ]
          )

        {:ok,
         %{
           conn: conn,
           stream: stream,
           peer_connection: pc,
           video_track_id: nil,
           video_reader: nil,
           video_payloader: nil,
           last_video_timestamp: Enum.random(0..@max_rtp_timestamp),
           audio_track_id: nil,
           audio_reader: nil,
           last_audio_timestamp: Enum.random(0..@max_rtp_timestamp),
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
  def handle_info(:send_video_frame, state) do
    Process.send_after(self(), :send_video_frame, 30)

    case IVFReader.next_frame(state.video_reader) do
      {:ok, frame} ->
        {rtp_packets, payloader} = VP8Payloader.payload(state.video_payloader, frame.data)

        # the video has 30 FPS, VP8 clock rate is 90_000, so we have:
        # 90_000 / 30 = 3_000
        last_timestamp = state.last_video_timestamp + 3_000 &&& @max_rtp_timestamp

        rtp_packets =
          Enum.map(rtp_packets, fn rtp_packet -> %{rtp_packet | timestamp: last_timestamp} end)

        Enum.each(rtp_packets, fn rtp_packet ->
          PeerConnection.send_rtp(state.peer_connection, state.video_track_id, rtp_packet)
        end)

        {:noreply, %{state | video_payloader: payloader, last_video_timestamp: last_timestamp}}

      :eof ->
        Logger.info("video.ivf ended. Looping...")
        {:ok, reader} = IVFReader.open("./video.ivf")
        {:ok, _header} = IVFReader.read_header(reader)
        {:noreply, %{state | video_reader: reader}}
    end
  end

  @impl true
  def handle_info(:send_audio_packet, state) do
    Process.send_after(self(), :send_audio_packet, 20)

    # TODO: implement
    case OggReader.next_packet(state.audio_reader) do
      {:ok, reader, packet} ->
        last_timestamp = state.last_audio_timestamp + 960
        rtp_packet = ExRTP.Packet.new(packet, 111, last_timestamp, 5, 5)
        PeerConnection.send_rtp(state.peer_connection, state.audio_track_id, rtp_packet)

        {:noreply, %{state | audio_reader: reader, last_audio_timestamp: last_timestamp}}
      _else ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(msg, state) do
    Logger.warning("Received unknown msg: #{inspect(msg)}")
    {:noreply, state}
  end

  defp handle_ws_message(
         %{"role" => _role, "type" => "peer_joined"},
         %{peer_connection: pc} = state
       ) do
    audio_track = MediaStreamTrack.new(:audio)
    video_track = MediaStreamTrack.new(:video)

    {:ok, _} = PeerConnection.add_track(pc, audio_track)
    {:ok, _} = PeerConnection.add_track(pc, video_track)

    {:ok, offer} = PeerConnection.create_offer(pc)
    :ok = PeerConnection.set_local_description(pc, offer)
    msg = %{"type" => "offer", "sdp" => offer.sdp}
    :gun.ws_send(state.conn, state.stream, {:text, Jason.encode!(msg)})

    %{state | video_track_id: video_track.id, audio_track_id: audio_track.id}
  end

  defp handle_ws_message(%{"type" => "answer", "sdp" => sdp}, state) do
    Logger.info("Received SDP answer: #{inspect(sdp)}")
    answer = %SessionDescription{type: :answer, sdp: sdp}
    :ok = PeerConnection.set_remote_description(state.peer_connection, answer)
    state
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

    state
  end

  defp handle_ws_message(msg, state) do
    Logger.info("Received unexpected message: #{inspect(msg)}")
    state
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

  defp handle_webrtc_message({:connection_state_change, :connected} = msg, state) do
    Logger.info("#{inspect(msg)}")
    Logger.info("Starting sending video.ivf and audio.ogg...")
    {:ok, ivf_reader} = IVFReader.open("./video.ivf")
    {:ok, _header} = IVFReader.read_header(ivf_reader)
    vp8_payloader = VP8Payloader.new(800)

    {:ok, ogg_reader} = OggReader.open("./audio.ogg")

    Process.send_after(self(), :send_video_frame, 30)
    Process.send_after(self(), :send_audio_packet, 20)
    %{state | video_reader: ivf_reader, video_payloader: vp8_payloader, audio_reader: ogg_reader}
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
