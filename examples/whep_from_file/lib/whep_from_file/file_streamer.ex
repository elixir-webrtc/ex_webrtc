defmodule WHEPFromFile.FileStreamer do
  @moduledoc """
  In the whep_from_file example, this FileStreamer is really only responsible for reading
  the media files and sending them to a list of viewers.

  The only real WebRTC piece of this file is the RTP packetization of the media. By creating the RTP packets
  close to where the media is being read, we only have to packetize the data once and then just send each
  of the viewers a copy.
  """
  use GenServer

  require Logger

  import Bitwise

  alias ExWebRTC.Media.{IVF, Ogg}
  alias ExWebRTC.RTP.{OpusPayloader, VP8Payloader}

  @video_file "./video.ivf"
  @audio_file "./audio.ogg"

  @max_rtp_timestamp (1 <<< 32) - 1

  def start_link(options) do
    GenServer.start_link(__MODULE__, options, name: WHEPFromFile.FileStreamer)
  end

  def add_viewer(viewer) do
    GenServer.cast(WHEPFromFile.FileStreamer, {:add_viewer, viewer})
  end

  @impl true
  def init(_) do
    {:ok, _header, video_reader} = IVF.Reader.open(@video_file)
    video_payloader = VP8Payloader.new(800)

    {:ok, audio_reader} = Ogg.Reader.open(@audio_file)

    state = %{
      video_reader: video_reader,
      video_payloader: video_payloader,
      audio_reader: audio_reader,
      last_video_timestamp: Enum.random(0..@max_rtp_timestamp),
      last_audio_timestamp: Enum.random(0..@max_rtp_timestamp),
      viewers: []
    }

    send(self(), :stream_video)
    send(self(), :stream_audio)
    Logger.info("Started video / audio stream")

    {:ok, state}
  end

  @impl true
  def handle_cast({:add_viewer, viewer_pid}, state) do
    {:noreply, %{state | viewers: [viewer_pid | state.viewers]}}
  end

  @impl true
  def handle_info(:stream_video, state) do
    # 30 =~ 1000 millisecond / 30 FPS
    Process.send_after(self(), :stream_video, 30)

    case IVF.Reader.next_frame(state.video_reader) do
      {:ok, frame} ->
        {rtp_packets, payloader} = VP8Payloader.payload(state.video_payloader, frame.data)

        # 3_000 = 90_000 (VP8 clock rate) / 30 FPS
        last_timestamp = state.last_video_timestamp + 3_000 &&& @max_rtp_timestamp

        rtp_packets =
          Enum.map(rtp_packets, fn rtp_packet -> %{rtp_packet | timestamp: last_timestamp} end)

        Enum.each(rtp_packets, fn rtp_packet ->
          Enum.each(state.viewers, fn viewer_pid ->
            send(viewer_pid, {:video_rtp, rtp_packet})
          end)
        end)

        {:noreply, %{state | video_payloader: payloader, last_video_timestamp: last_timestamp}}

      :eof ->
        Logger.info("Video file finished. Looping...")
        {:ok, _header, reader} = IVF.Reader.open(@video_file)
        {:noreply, %{state | video_reader: reader}}

      {:error, reason} ->
        Logger.error("Error when reading IVF, reason: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  def handle_info(:stream_audio, state) do
    case Ogg.Reader.next_packet(state.audio_reader) do
      {:ok, {packet, duration}, reader} ->
        # in real-life scenario, you will need to conpensate for `Process.send_after/3` error
        # and time spent on reading and parsing the file
        Process.send_after(self(), :stream_audio, duration)

        rtp_packet = OpusPayloader.payload(packet)
        rtp_packet = %{rtp_packet | timestamp: state.last_audio_timestamp}
        # PeerConnection.send_rtp(state.peer_connection, state.audio_track_id, rtp_packet)
        Enum.each(state.viewers, fn viewer_pid ->
          send(viewer_pid, {:audio_rtp, rtp_packet})
        end)

        # Ogg.Reader.next_packet/1 returns duration in ms
        # we have to convert it to RTP timestamp difference
        timestamp_delta = trunc(duration * 48_000 / 1000)
        new_timestamp = state.last_audio_timestamp + timestamp_delta

        state = %{state | audio_reader: reader, last_audio_timestamp: new_timestamp}
        {:noreply, state}

      :eof ->
        send(self(), :stream_audio)
        Logger.info("Audio file finished. Looping...")
        {:ok, reader} = Ogg.Reader.open(@audio_file)
        {:noreply, %{state | audio_reader: reader}}

      {:error, reason} ->
        Logger.error("Error when reading Ogg, reason: #{inspect(reason)}")
        {:noreply, state}
    end
  end
end
