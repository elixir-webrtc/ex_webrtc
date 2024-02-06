defmodule SendFromFile.PeerHandler do
  require Logger

  import Bitwise

  alias ExWebRTC.{
    ICECandidate,
    MediaStreamTrack,
    PeerConnection,
    RTPCodecParameters,
    SessionDescription
  }

  alias ExWebRTC.Media.{IVF, Ogg}
  alias ExWebRTC.RTP.{OpusPayloader, VP8Payloader}

  @behaviour WebSock

  @video_file "./video.ivf"
  @audio_file "./audio.ogg"

  @max_rtp_timestamp (1 <<< 32) - 1

  @ice_servers [
    %{urls: "stun:stun.l.google.com:19302"}
  ]

  @video_codecs [
    %RTPCodecParameters{
      payload_type: 96,
      mime_type: "video/VP8",
      clock_rate: 90_000
    }
  ]

  @audio_codecs [
    %RTPCodecParameters{
      payload_type: 111,
      mime_type: "audio/opus",
      clock_rate: 48_000,
      channels: 2
    }
  ]

  @impl true
  def init(_) do
    {:ok, pc} =
      PeerConnection.start_link(
        ice_servers: @ice_servers,
        video_codecs: @video_codecs,
        audio_codecs: @audio_codecs
      )

    video_track = MediaStreamTrack.new(:video)
    audio_track = MediaStreamTrack.new(:audio)

    {:ok, _sender} = PeerConnection.add_track(pc, video_track)
    {:ok, _sender} = PeerConnection.add_track(pc, audio_track)

    {:ok, _header, video_reader} = IVF.Reader.open(@video_file)
    video_payloader = VP8Payloader.new(800)

    {:ok, audio_reader} = Ogg.Reader.open(@audio_file)

    state = %{
      peer_connection: pc,
      video_track_id: video_track.id,
      audio_track_id: audio_track.id,
      video_reader: video_reader,
      video_payloader: video_payloader,
      audio_reader: audio_reader,
      last_video_timestamp: Enum.random(0..@max_rtp_timestamp),
      last_audio_timestamp: Enum.random(0..@max_rtp_timestamp)
    }

    {:ok, offer} = PeerConnection.create_offer(pc)
    :ok = PeerConnection.set_local_description(pc, offer)

    offer_json = SessionDescription.to_json(offer)

    msg =
      %{"type" => "offer", "data" => offer_json}
      |> Jason.encode!()

    Logger.info("Sent SDP offer: #{inspect(offer_json)}")

    {:push, {:text, msg}, state}
  end

  @impl true
  def handle_in({msg, [opcode: :text]}, state) do
    msg
    |> Jason.decode!()
    |> handle_ws_msg(state)

    {:ok, state}
  end

  @impl true
  def handle_info({:ex_webrtc, _from, msg}, state) do
    handle_webrtc_msg(msg, state)
  end

  @impl true
  def handle_info(:send_video, state) do
    # 30 =~ 1000 millisecond / 30 FPS
    Process.send_after(self(), :send_video, 30)

    case IVF.Reader.next_frame(state.video_reader) do
      {:ok, frame} ->
        {rtp_packets, payloader} = VP8Payloader.payload(state.video_payloader, frame.data)

        # 3_000 = 90_000 (VP8 clock rate) / 30 FPS
        last_timestamp = state.last_video_timestamp + 3_000 &&& @max_rtp_timestamp

        rtp_packets =
          Enum.map(rtp_packets, fn rtp_packet -> %{rtp_packet | timestamp: last_timestamp} end)

        Enum.each(rtp_packets, fn rtp_packet ->
          PeerConnection.send_rtp(state.peer_connection, state.video_track_id, rtp_packet)
        end)

        {:ok, %{state | video_payloader: payloader, last_video_timestamp: last_timestamp}}

      :eof ->
        Logger.info("Video file finished. Looping...")
        {:ok, _header, reader} = IVF.Reader.open(@video_file)
        {:ok, %{state | video_reader: reader}}

      {:error, reason} ->
        Logger.error("Error when reading IVF, reason: #{inspect(reason)}")
        {:ok, state}
    end
  end

  @impl true
  def handle_info(:send_audio, state) do
    case Ogg.Reader.next_packet(state.audio_reader) do
      {:ok, {packet, duration}, reader} ->
        # in real-life scenario, you will need to conpensate for `Process.send_after/3` error
        # and time spent on reading and parsing the file
        Process.send_after(self(), :send_audio, duration)

        rtp_packet = OpusPayloader.payload(packet)
        rtp_packet = %{rtp_packet | timestamp: state.last_audio_timestamp}
        PeerConnection.send_rtp(state.peer_connection, state.audio_track_id, rtp_packet)

        # Ogg.Reader.next_packet/1 returns duration in ms
        # we have to convert it to RTP timestamp difference
        timestamp_delta = trunc(duration * 48_000 / 1000)
        new_timestamp = state.last_audio_timestamp + timestamp_delta

        state = %{state | audio_reader: reader, last_audio_timestamp: new_timestamp}
        {:ok, state}

      :eof ->
        send(self(), :send_audio)
        Logger.info("Audio file finished. Looping...")
        {:ok, reader} = Ogg.Reader.open(@audio_file)
        {:ok, %{state | audio_reader: reader}}

      {:error, reason} ->
        Logger.error("Error when reading Ogg, reason: #{inspect(reason)}")
        {:ok, state}
    end
  end

  @impl true
  def terminate(reason, _state) do
    Logger.warning("WebSocket connection was terminated, reason: #{inspect(reason)}")
  end

  defp handle_ws_msg(%{"type" => "answer", "data" => data}, state) do
    Logger.info("Received SDP answer: #{inspect(data)}")

    answer = SessionDescription.from_json(data)
    :ok = PeerConnection.set_remote_description(state.peer_connection, answer)
  end

  defp handle_ws_msg(%{"type" => "ice", "data" => data}, state) do
    Logger.info("Received ICE candidate: #{inspect(data)}")

    candidate = ICECandidate.from_json(data)
    :ok = PeerConnection.add_ice_candidate(state.peer_connection, candidate)
  end

  defp handle_webrtc_msg({:ice_candidate, candidate}, state) do
    candidate_json = ICECandidate.to_json(candidate)

    msg =
      %{"type" => "ice", "data" => candidate_json}
      |> Jason.encode!()

    Logger.info("Sent ICE candidate: #{inspect(candidate_json)}")

    {:push, {:text, msg}, state}
  end

  defp handle_webrtc_msg({:connection_state_change, :connected}, state) do
    Logger.info("Connection established, starting to send media")

    send(self(), :send_video)
    send(self(), :send_audio)

    {:ok, state}
  end

  defp handle_webrtc_msg(_msg, state), do: {:ok, state}
end
