defmodule ExWebRTC.Recorder.Converter do
  @moduledoc """
  Processes RTP packet files saved by `Recorder`.

  At the moment, `Converter` works only with VP8 video and Opus audio.
  """

  require Logger

  alias ExWebRTC.RTP.JitterBuffer.PacketStore
  alias ExWebRTC.RTPCodecParameters
  alias ExWebRTC.RTP.Depayloader
  alias ExWebRTC.Media.{IVF, Ogg}

  # TODO: Allow changing these values
  @ivf_header_opts [
    # <<fourcc::little-32>> = "VP80"
    fourcc: 808_996_950,
    height: 720,
    width: 1280,
    num_frames: 1024,
    timebase_denum: 24,
    timebase_num: 1
  ]

  # TODO: Support codecs other than VP8/Opus
  @video_codec_params %RTPCodecParameters{
    payload_type: 96,
    mime_type: "video/VP8",
    clock_rate: 90_000
  }

  @audio_codec_params %RTPCodecParameters{
    payload_type: 111,
    mime_type: "audio/opus",
    clock_rate: 48_000,
    channels: 2
  }

  @default_output_path "./converter_output"

  @doc """
  Convert the saved dumps of tracks in the report to IVF and Ogg files.
  """
  @spec convert!(Path.t(), Path.t()) :: :ok | no_return()
  def convert!(report_path, output_path \\ @default_output_path) do
    report_path =
      report_path
      |> Path.expand()
      |> then(
        &if(File.dir?(&1),
          do: Path.join(&1, "report.json"),
          else: &1
        )
      )

    output_path = Path.expand(output_path)
    File.mkdir_p!(output_path)

    report =
      report_path
      |> File.read!()
      |> Jason.decode!()

    for {id, track} <- report do
      %{
        "path" => path,
        "kind" => kind,
        "rid_map" => rid_map
      } = track

      file = File.open!(path)

      packets =
        read_packets(file, Map.new(rid_map, fn {_rid, rid_idx} -> {rid_idx, %PacketStore{}} end))

      case kind do
        "video" ->
          convert_video_track(id, rid_map, output_path, packets)

        "audio" ->
          {:ok, writer} =
            output_path
            |> Path.join("#{id}.ogg")
            |> Ogg.Writer.open()

          {:ok, depayloader} = Depayloader.new(@audio_codec_params)
          do_convert_audio_track(packets |> Map.values() |> hd(), depayloader, writer)
      end
    end

    :ok
  end

  defp convert_video_track(id, rid_map, output_path, packets) do
    for {rid, rid_idx} <- rid_map do
      filename = if rid == "nil", do: "#{id}.ivf", else: "#{id}_#{rid}.ivf"

      {:ok, writer} =
        output_path
        |> Path.join(filename)
        |> IVF.Writer.open(@ivf_header_opts)

      {:ok, depayloader} = Depayloader.new(@video_codec_params)
      do_convert_video_track(packets[rid_idx], depayloader, writer)
    end
  end

  defp do_convert_video_track(packets, depayloader, writer, frames_cnt \\ 0)
  defp do_convert_video_track([], _depayloader, writer, _frames_cnt), do: IVF.Writer.close(writer)

  defp do_convert_video_track([packet | rest], depayloader, writer, frames_cnt) do
    case Depayloader.depayload(depayloader, packet) do
      {nil, depayloader} ->
        do_convert_video_track(rest, depayloader, writer, frames_cnt)

      {vp8_frame, depayloader} ->
        frame = %IVF.Frame{timestamp: frames_cnt, data: vp8_frame}
        {:ok, writer} = IVF.Writer.write_frame(writer, frame)
        do_convert_video_track(rest, depayloader, writer, frames_cnt + 1)
    end
  end

  defp do_convert_audio_track([], _depayloader, writer), do: Ogg.Writer.close(writer)

  defp do_convert_audio_track([packet | rest], depayloader, writer) do
    {opus_packet, depayloader} = Depayloader.depayload(depayloader, packet)
    {:ok, writer} = Ogg.Writer.write_packet(writer, opus_packet)
    do_convert_audio_track(rest, depayloader, writer)
  end

  defp read_packets(file, stores) do
    case read_packet(file) do
      {:ok, rid_idx, packet} ->
        stores = Map.update!(stores, rid_idx, &insert_packet_to_store(&1, packet))
        read_packets(file, stores)

      {:error, :not_enough_data} ->
        Logger.warning("Error decoding RTP packet")
        read_packets(file, stores)

      :eof ->
        Map.new(stores, fn {rid_idx, store} ->
          {rid_idx, store |> PacketStore.dump() |> Enum.reject(&is_nil/1)}
        end)
    end
  end

  defp read_packet(file) do
    case IO.binread(file, 13) do
      <<rid_idx::8, _recv_time::64, packet_size::32>> ->
        with {:ok, packet} <- file |> IO.binread(packet_size) |> ExRTP.Packet.decode() do
          {:ok, rid_idx, packet}
        end

      :eof ->
        :eof
    end
  end

  defp insert_packet_to_store(store, packet) do
    case PacketStore.insert(store, packet) do
      {:ok, store} ->
        store

      {:error, :late_packet} ->
        Logger.warning("Decoded late RTP packet")
        store
    end
  end
end
