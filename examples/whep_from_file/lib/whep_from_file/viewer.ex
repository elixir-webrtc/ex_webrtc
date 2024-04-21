defmodule WHEPFromFile.Viewer do
  @moduledoc """
  The Viewer GenServer is responsible for managing the state of a single viewer.

  For the whep_from_file example, we made codec assumptions based on the static files, however
  in a real life example you would fetch the codecs from the stream source and pass those as part
  the PeerConnection configuration.
  """
  use GenServer

  require Logger

  alias ExWebRTC.{
    MediaStreamTrack,
    PeerConnection,
    RTPCodecParameters,
    SessionDescription
  }

  @ice_servers [
    # %{urls: "stun:stun.l.google.com:19302"}
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

  def start_link(viewer_id) do
    GenServer.start_link(__MODULE__, viewer_id, name: via_tuple(viewer_id))
  end

  def child_spec(viewer_id) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [viewer_id]},
      restart: :temporary
    }
  end

  def watch_stream(viewer_id, offer) do
    Logger.info("Starting stream for #{viewer_id}")
    viewer_id |> via_tuple() |> GenServer.call({:whep, offer})
  end

  def stop_stream(viewer_id, stop_reason \\ :normal) do
    Logger.info("Stopping stream for #{viewer_id}")
    viewer_id |> via_tuple() |> GenServer.stop(stop_reason)
  end

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

    state = %{
      peer_connection: pc,
      video_track: video_track,
      audio_track: audio_track,
      video_track_id: video_track.id,
      audio_track_id: audio_track.id,
      viewers: []
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:whep, offer}, _from, state) do
    Logger.info("Got SDP offer: #{offer}")

    :ok =
      PeerConnection.set_remote_description(state.peer_connection, %SessionDescription{
        type: :offer,
        sdp: offer
      })

    {:ok, answer} = PeerConnection.create_answer(state.peer_connection)
    :ok = PeerConnection.set_local_description(state.peer_connection, answer)

    answer = PeerConnection.get_current_local_description(state.peer_connection)

    Logger.info("Sent SDP offer: #{answer.sdp}")

    {:reply, {:ok, answer.sdp}, state}
  end

  @impl true
  def handle_info({:video_rtp, packet}, state) do
    PeerConnection.send_rtp(state.peer_connection, state.video_track_id, packet)
    {:noreply, state}
  end

  def handle_info({:audio_rtp, packet}, state) do
    PeerConnection.send_rtp(state.peer_connection, state.audio_track_id, packet)
    {:noreply, state}
  end

  def handle_info({:ex_webrtc, _from, msg}, state) do
    handle_webrtc_msg(msg, state)
  end

  defp handle_webrtc_msg({:connection_state_change, :connected}, state) do
    Logger.info("Viewer established, starting to send media")
    WHEPFromFile.FileStreamer.add_viewer(self())

    {:noreply, state}
  end

  defp handle_webrtc_msg(_msg, state), do: {:noreply, state}

  # Private
  defp via_tuple(name),
    do: {:via, Registry, {:viewer_registry, name}}
end
