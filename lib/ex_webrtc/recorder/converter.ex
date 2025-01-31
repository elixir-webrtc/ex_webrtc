defmodule ExWebRTC.Recorder.Converter do
  @moduledoc """
  Processes RTP packet files saved by `Recorder`.

  At the moment, `Converter` works only with VP8 video and Opus audio.
  """

  require Logger

  alias ExWebRTC.RTP.JitterBuffer.PacketStore
  alias ExWebRTC.RTP.Depayloader
  alias ExWebRTC.Media.{IVF, Ogg}
  alias ExWebRTC.Recorder.S3
  alias ExWebRTC.{Recorder, RTPCodecParameters}

  # TODO: Allow changing these values
  @ivf_header_opts [
    # <<fourcc::little-32>> = "VP80"
    fourcc: 808_996_950,
    height: 720,
    width: 1280,
    num_frames: 1024,
    timebase_denum: 30,
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

  @default_output_path "./converter/output"
  @default_download_path "./converter/download"

  @typep file_manifest :: %{
           location: String.t()
         }

  # XXX this probably shouldn't be opaque
  @opaque manifest :: %{ExWebRTC.MediaStreamTrack.stream_id() => file_manifest()}

  @doc """
  Convert the saved dumps of tracks in the report to IVF and Ogg files.
  """
  # REWRITEME
  @spec convert!(Path.t(), Path.t()) :: term() | no_return()
  def convert!(report_path, output_path \\ @default_output_path) do
    report_path =
      report_path
      |> Path.expand()
      |> then(
        &if(File.dir?(&1),
          do: Path.join(&1, "manifest.json"),
          else: &1
        )
      )

    report =
      report_path
      |> File.read!()
      |> Jason.decode!()

    # XXX no maikel this is so not right
    convert_manifest!(report, output_path)
  end

  # XXX type options + docs
  @spec convert_manifest!(Recorder.manifest(), keyword()) :: manifest() | no_return()
  def convert_manifest!(manifest, options)

  def convert_manifest!(manifest, options) when map_size(manifest) > 0 do
    output_path = Keyword.get(options, :output_path, @default_output_path) |> Path.expand()
    download_path = Keyword.get(options, :download_path, @default_download_path) |> Path.expand()
    File.mkdir_p!(output_path)
    File.mkdir_p!(download_path)

    download_config = Keyword.get(options, :s3_download_config, [])

    upload_handler =
      if options[:s3_upload_config] do
        Logger.info("Converted recordings will be uploaded to S3 WRITEME")
        S3.UploadHandler.new(options[:s3_upload_config])
      end

    output_manifest =
      manifest
      |> fetch_remote_files!(download_path, download_config)
      |> do_convert_manifest!(output_path)

    result_manifest =
      if upload_handler != nil do
        {ref, upload_handler} = S3.UploadHandler.spawn_task(upload_handler, output_manifest)

        # XXX What if upload fails?
        {:ok, download_manifest, _handler} =
          receive do
            {^ref, _res} = task_result ->
              S3.UploadHandler.process_result(upload_handler, task_result)
          end

        download_manifest
      else
        output_manifest
      end

    result_manifest |> IO.inspect(label: :FINAL_RESULT_MANIFEST)
  end

  def convert_manifest!(_empty_manifest, _options), do: %{}

  # def convert_report!(report, output_path \\ @default_output_path) do
  #   output_path = Path.expand(output_path)
  #   File.mkdir_p!(output_path)

  defp fetch_remote_files!(manifest, dl_path, dl_config) do
    Map.new(manifest, fn {track_id, %{location: location} = track_data} ->
      scheme = URI.parse(location).scheme || "file"

      {:ok, local_path} =
        case scheme do
          "file" -> {:ok, String.replace_prefix(location, "file://", "")}
          "s3" -> fetch_from_s3(location, dl_path, dl_config)
        end

      {track_id, %{track_data | location: Path.expand(local_path)}}
    end)
  end

  defp fetch_from_s3(url, dl_path, dl_config) do
    # XXX print (some) S3 config used?
    Logger.info("Fetching file #{url}")

    with {:ok, bucket_name, s3_path} <- S3.Utils.parse_url(url),
         out_path <- Path.join(dl_path, Path.basename(s3_path)),
         {:ok, _result} <- S3.Utils.fetch_file(bucket_name, s3_path, out_path, dl_config) do
      {:ok, out_path}
    else
      # XXX descriptive errors
      _other -> :error
    end
  end

  defp do_convert_manifest!(manifest, output_path) do
    stream_map =
      Enum.reduce(manifest, %{}, fn {id, track}, stream_map ->
        %{
          location: path,
          kind: kind,
          streams: streams,
          rid_map: rid_map
        } = track

        file = File.open!(path)

        packets =
          read_packets(
            file,
            Map.new(rid_map, fn {_rid, rid_idx} -> {rid_idx, %PacketStore{}} end)
          )

        output_metadata =
          case kind do
            :video ->
              convert_video_track(id, rid_map, output_path, packets)

            :audio ->
              %{nil: convert_audio_track(id, output_path, packets |> Map.values() |> hd())}
          end

        stream_id = List.first(streams)

        stream_map
        |> Map.put_new(stream_id, %{video: %{}, audio: %{}})
        |> Map.update!(stream_id, &Map.put(&1, kind, output_metadata))
      end)

    for {stream_id, %{video: video_files, audio: audio_files}} <- stream_map,
        {rid, %{filename: video_file, start_time: video_start}} <- video_files,
        {nil, %{filename: audio_file, start_time: audio_start}} <- audio_files,
        into: %{} do
      {video_start_time, audio_start_time} = calculate_start_times(video_start, audio_start)
      output_id = if rid == nil, do: stream_id, else: "#{stream_id}_#{rid}"

      output_file = Path.join(output_path, "#{output_id}.webm")

      {_io, 0} =
        System.cmd(
          "ffmpeg",
          [
            "-ss",
            video_start_time,
            "-i",
            Path.join(output_path, video_file),
            "-ss",
            audio_start_time,
            "-i",
            Path.join(output_path, audio_file),
            "-c:v",
            "copy",
            "-c:a",
            "copy",
            "-shortest",
            output_file
          ],
          stderr_to_stdout: true
        )

      {output_id, %{location: output_file}}
    end
  end

  defp convert_video_track(id, rid_map, output_path, packets) do
    for {rid, rid_idx} <- rid_map, into: %{} do
      filename = if rid == nil, do: "#{id}.ivf", else: "#{id}_#{rid}.ivf"

      {:ok, writer} =
        output_path
        |> Path.join(filename)
        |> IVF.Writer.open(@ivf_header_opts)

      {:ok, depayloader} = Depayloader.new(@video_codec_params)

      conversion_state = %{
        depayloader: depayloader,
        writer: writer,
        frames_cnt: 0
      }

      start_time = do_convert_video_track(packets[rid_idx], conversion_state)

      {rid, %{filename: filename, start_time: start_time}}
    end
  end

  defp do_convert_video_track([], %{writer: writer} = state) do
    IVF.Writer.close(writer)

    state[:first_frame_recv_time]
  end

  defp do_convert_video_track([packet | rest], state) do
    case Depayloader.depayload(state.depayloader, packet) do
      {nil, depayloader} ->
        do_convert_video_track(rest, %{state | depayloader: depayloader})

      {vp8_frame, depayloader} ->
        {:ok, %ExRTP.Packet.Extension{id: 1, data: <<recv_time::64>>}} =
          ExRTP.Packet.fetch_extension(packet, 1)

        frame = %IVF.Frame{timestamp: state.frames_cnt, data: vp8_frame}
        {:ok, writer} = IVF.Writer.write_frame(state.writer, frame)

        state =
          %{state | depayloader: depayloader, writer: writer, frames_cnt: state.frames_cnt + 1}
          |> Map.put_new(:first_frame_recv_time, recv_time)

        do_convert_video_track(rest, state)
    end
  end

  defp convert_audio_track(id, output_path, packets) do
    filename = "#{id}.ogg"

    {:ok, writer} =
      output_path
      |> Path.join(filename)
      |> Ogg.Writer.open()

    {:ok, depayloader} = Depayloader.new(@audio_codec_params)

    # XXX ugleh
    start_time = do_convert_audio_track(packets, %{depayloader: depayloader, writer: writer})

    %{filename: filename, start_time: start_time}
  end

  defp do_convert_audio_track([], %{writer: writer} = state) do
    Ogg.Writer.close(writer)

    state[:first_frame_recv_time]
  end

  defp do_convert_audio_track([packet | rest], state) do
    {opus_packet, depayloader} = Depayloader.depayload(state.depayloader, packet)

    {:ok, %ExRTP.Packet.Extension{id: 1, data: <<recv_time::64>>}} =
      ExRTP.Packet.fetch_extension(packet, 1)

    {:ok, writer} = Ogg.Writer.write_packet(state.writer, opus_packet)

    state =
      %{state | depayloader: depayloader, writer: writer}
      |> Map.put_new(:first_frame_recv_time, recv_time)

    do_convert_audio_track(rest, state)
  end

  defp read_packets(file, stores) do
    case read_packet(file) do
      {:ok, rid_idx, recv_time, packet} ->
        packet =
          ExRTP.Packet.add_extension(packet, %ExRTP.Packet.Extension{
            id: 1,
            data: <<recv_time::64>>
          })

        stores = Map.update!(stores, rid_idx, &insert_packet_to_store(&1, packet))
        read_packets(file, stores)

      {:error, reason} ->
        Logger.warning("Error decoding RTP packet: #{inspect(reason)}")
        read_packets(file, stores)

      :eof ->
        Map.new(stores, fn {rid_idx, store} ->
          {rid_idx, store |> PacketStore.dump() |> Enum.reject(&is_nil/1)}
        end)
    end
  end

  defp read_packet(file) do
    with {:ok, <<rid_idx::8, recv_time::64, packet_size::32>>} <- read_exactly_n_bytes(file, 13),
         {:ok, packet_data} <- read_exactly_n_bytes(file, packet_size),
         {:ok, packet} <- ExRTP.Packet.decode(packet_data) do
      {:ok, rid_idx, recv_time, packet}
    end
  end

  defp read_exactly_n_bytes(file, byte_cnt) do
    with data when is_binary(data) <- IO.binread(file, byte_cnt),
         true <- byte_cnt == byte_size(data) do
      {:ok, data}
    else
      :eof -> :eof
      false -> {:error, :not_enough_data}
      {:error, _reason} = error -> error
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

  defp calculate_start_times(video_start_ms, audio_start_ms) do
    diff = abs(video_start_ms - audio_start_ms)
    s = div(diff, 1000)
    ms = rem(diff, 1000)
    delayed_start_time = :io_lib.format("00:00:~2..0w.~3..0w", [s, ms]) |> to_string()

    if video_start_ms > audio_start_ms,
      do: {"00:00:00.000", delayed_start_time},
      else: {delayed_start_time, "00:00:00.000"}
  end
end
