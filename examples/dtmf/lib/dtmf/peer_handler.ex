defmodule Dtmf.PeerHandler do
  require Logger

  alias ExWebRTC.{
    ICECandidate,
    MediaStreamTrack,
    PeerConnection,
    RTPCodecParameters,
    RTP.Depayloader,
    RTP.JitterBuffer,
    SessionDescription
  }

  @behaviour WebSock

  @ice_servers [
    %{urls: "stun:stun.l.google.com:19302"}
  ]

  @audio_codecs [
    %RTPCodecParameters{
      payload_type: 111,
      mime_type: "audio/opus",
      clock_rate: 48_000,
      channels: 2
    },
    %RTPCodecParameters{
      payload_type: 126,
      mime_type: "audio/telephone-event",
      clock_rate: 8000,
      channels: 1
    }
  ]

  @impl true
  def init(_) do
    {:ok, pc} =
      PeerConnection.start_link(
        ice_servers: @ice_servers,
        video_codecs: [],
        audio_codecs: @audio_codecs
      )

    state = %{
      peer_connection: pc,
      in_audio_track_id: nil,
      # The flow of this example is as follows:
      # we first feed rtp packets into jitter buffer to
      # wait for retransmissions and fix ordering.
      # Once ordering and gaps are fixed, we feed packets
      # to the depayloader, which detects DTMF events.
      # Note that depayloader takes all RTP packets (both Opus and DTMF),
      # but ignores those that are not DTMF ones.
      # This is to avoid demuxing packets by the user.
      jitter_buffer: nil,
      jitter_timer: nil,
      depayloader: nil
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
  def handle_info(:jitter_buffer_timeout, state) do
    state = %{state | jitter_timer: nil}

    state.jitter_buffer
    |> JitterBuffer.handle_timeout()
    |> handle_jitter_buffer_result(state)
  end

  @impl true
  def handle_info({:EXIT, pc, reason}, %{peer_connection: pc} = state) do
    # Bandit traps exits under the hood so our PeerConnection.start_link
    # won't automatically bring this process down.
    Logger.info("Peer connection process exited, reason: #{inspect(reason)}")
    {:stop, {:shutdown, :pc_closed}, state}
  end

  @impl true
  def terminate(reason, _state) do
    Logger.info("WebSocket connection was terminated, reason: #{inspect(reason)}")
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

  defp handle_webrtc_msg({:connection_state_change, conn_state}, state) do
    Logger.info("Connection state changed: #{conn_state}")

    if conn_state in [:failed, :closed] do
      {:stop, {:shutdown, :pc_failed_or_closed}, state}
    else
      {:ok, state}
    end
  end

  defp handle_webrtc_msg({:ice_candidate, candidate}, state) do
    candidate_json = ICECandidate.to_json(candidate)

    msg =
      %{"type" => "ice", "data" => candidate_json}
      |> Jason.encode!()

    Logger.info("Sent ICE candidate: #{candidate_json["candidate"]}")

    {:push, {:text, msg}, state}
  end

  defp handle_webrtc_msg({:track, %MediaStreamTrack{kind: :audio, id: id}}, state) do
    # Find dtmf codec. Its config (payload type) might have changed during negotiation.
    tr =
      state.peer_connection
      |> PeerConnection.get_transceivers()
      |> Enum.find(fn tr -> tr.receiver.track.id == id end)

    codec = Enum.find(tr.codecs, fn codec -> codec.mime_type == "audio/telephone-event" end)

    if codec == nil do
      raise "DTMF for the track has not been negotiated."
    end

    jitter_buffer = JitterBuffer.new()
    {:ok, depayloader} = Depayloader.new(codec)

    state = %{
      state
      | in_audio_track_id: id,
        jitter_buffer: jitter_buffer,
        depayloader: depayloader
    }

    {:ok, state}
  end

  defp handle_webrtc_msg({:rtp, id, nil, packet}, %{in_audio_track_id: id} = state) do
    state.jitter_buffer
    |> JitterBuffer.insert(packet)
    |> handle_jitter_buffer_result(state)
  end

  defp handle_webrtc_msg(_msg, state), do: {:ok, state}

  defp handle_jitter_buffer_result({packets, timeout, jitter_buffer}, state) do
    state = %{state | jitter_buffer: jitter_buffer}

    # set a new timer only if the previous one has expired
    state =
      if timeout != nil and state.jitter_timer == nil do
        timer = Process.send_after(self(), :jitter_buffer_timeout, timeout)
        %{state | jitter_timer: timer}
      else
        state
      end

    state =
      Enum.reduce(packets, state, fn packet, state ->
        case Depayloader.depayload(state.depayloader, packet) do
          {nil, depayloader} ->
            %{state | depayloader: depayloader}

          {event, depayloader} ->
            Logger.info("Received DTMF event: #{event.event}")
            %{state | depayloader: depayloader}
        end
      end)

    {:ok, state}
  end
end
