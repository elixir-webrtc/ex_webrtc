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
  @max_rtp_seq_no (1 <<< 16) - 1

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
      next_video_timestamp: Enum.random(0..@max_rtp_timestamp),
      next_audio_timestamp: Enum.random(0..@max_rtp_timestamp),
      next_video_sequence_number: Enum.random(0..@max_rtp_seq_no),
      next_audio_sequence_number: Enum.random(0..@max_rtp_seq_no),
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
        next_sequence_number =
          Enum.reduce(rtp_packets, state.next_video_sequence_number, fn packet, sequence_number ->
            packet = %{
              packet
              | timestamp: state.next_video_timestamp,
                sequence_number: sequence_number
            }

            Enum.each(state.viewers, fn viewer_pid ->
              send(viewer_pid, {:video_rtp, packet})
            end)

            sequence_number + 1 &&& @max_rtp_seq_no
          end)

        next_timestamp = state.next_video_timestamp + 3_000 &&& @max_rtp_timestamp

        state = %{
          state
          | video_payloader: payloader,
            next_video_timestamp: next_timestamp,
            next_video_sequence_number: next_sequence_number
        }

        {:noreply, state}

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

        rtp_packet = %{
          rtp_packet
          | timestamp: state.next_audio_timestamp,
            sequence_number: state.next_audio_sequence_number
        }

        Enum.each(state.viewers, fn viewer_pid ->
          send(viewer_pid, {:audio_rtp, rtp_packet})
        end)

        # Ogg.Reader.next_packet/1 returns duration in ms
        # we have to convert it to RTP timestamp difference
        timestamp_delta = trunc(duration * 48_000 / 1000)
        next_timestamp = state.next_audio_timestamp + timestamp_delta &&& @max_rtp_timestamp
        next_sequence_number = state.next_audio_sequence_number + 1 &&& @max_rtp_seq_no

        state = %{
          state
          | audio_reader: reader,
            next_audio_timestamp: next_timestamp,
            next_audio_sequence_number: next_sequence_number
        }

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
