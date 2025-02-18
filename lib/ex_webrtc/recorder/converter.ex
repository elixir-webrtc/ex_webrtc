defmodule ExWebRTC.Recorder.Converter do
  @moduledoc """
  Processes RTP packet files saved by `ExWebRTC.Recorder`.

  Requires the `ffmpeg` binary with the relevant libraries present in `PATH`.

  At the moment, `ExWebRTC.Recorder.Converter` works only with VP8 video and Opus audio.

  Can optionally download/upload the source/result files from/to S3-compatible storage.
  See `ExWebRTC.Recorder.S3` and `t:options/0` for more info.
  """

  alias ExWebRTC.RTP.JitterBuffer.PacketStore
  alias ExWebRTC.RTP.Depayloader
  alias ExWebRTC.Media.{IVF, Ogg}

  alias ExWebRTC.Recorder.S3
  alias ExWebRTC.{Recorder, RTPCodecParameters}

  alias __MODULE__.FFmpeg

  require Logger

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
  @default_thumbnail_width 640
  @default_thumbnail_height -1

  @typedoc """
  Context for the thumbnail generation.

  * `:width` - Thumbnail width. #{@default_thumbnail_width} by default.
  * `:height` - Thumbnail height. #{@default_thumbnail_height} by default.

  Setting either of the values to `-1` will fit the size to the aspect ratio.
  """
  @type thumbnails_ctx :: %{
          optional(:width) => pos_integer() | -1,
          optional(:height) => pos_integer() | -1
        }

  @typedoc """
  Options that can be passed to `convert_manifest!/2` and `convert_path!/2`.

  * `:output_path` - Directory where Converter will save its artifacts. `#{@default_output_path}` by default.
  * `:s3_upload_config` - If passed, processed recordings will be uploaded to S3-compatible storage.
    See `t:ExWebRTC.Recorder.S3.upload_config/0` for more info.
  * `:download_path` - Directory where Converter will save files fetched from S3. `#{@default_download_path}` by default.
  * `:s3_download_config` - Optional S3 config overrides used when fetching files.
    See `t:ExWebRTC.Recorder.S3.override_config/0` for more info.
  * `:thumbnails_ctx` - If passed, Converter will generate thumbnails for the output files.
    See `t:thumbnails_ctx/0` for more info.
  """
  @type option ::
          {:output_path, Path.t()}
          | {:s3_upload_config, keyword()}
          | {:download_path, Path.t()}
          | {:s3_download_config, keyword()}
          | {:thumbnails_ctx, thumbnails_ctx()}

  @type options :: [option()]

  @doc """
  Loads the recording manifest from file, then proceeds with `convert_manifest!/2`.
  """
  @spec convert_path!(Path.t(), options()) :: __MODULE__.Manifest.t() | no_return()
  def convert_path!(recorder_manifest_path, options \\ []) do
    recorder_manifest_path =
      recorder_manifest_path
      |> Path.expand()
      |> then(
        &if(File.dir?(&1),
          do: Path.join(&1, "manifest.json"),
          else: &1
        )
      )

    recorder_manifest =
      recorder_manifest_path
      |> File.read!()
      |> Jason.decode!()
      |> Recorder.Manifest.from_json!()

    convert_manifest!(recorder_manifest, options)
  end

  @doc """
  Converts the saved dumps of tracks in the manifest to WEBM files.
  """
  @spec convert_manifest!(Recorder.Manifest.t(), options()) ::
          __MODULE__.Manifest.t() | no_return()
  def convert_manifest!(recorder_manifest, options \\ [])

  def convert_manifest!(manifest, options) when map_size(manifest) > 0 do
    thumbnails_ctx =
      case Keyword.get(options, :thumbnails_ctx, nil) do
        nil ->
          nil

        ctx ->
          %{
            width: ctx[:width] || @default_thumbnail_width,
            height: ctx[:height] || @default_thumbnail_height
          }
      end

    output_path = Keyword.get(options, :output_path, @default_output_path) |> Path.expand()
    download_path = Keyword.get(options, :download_path, @default_download_path) |> Path.expand()
    File.mkdir_p!(output_path)
    File.mkdir_p!(download_path)

    download_config = Keyword.get(options, :s3_download_config, [])

    upload_handler =
      if options[:s3_upload_config] do
        Logger.info("Converted recordings will be uploaded to S3")
        S3.UploadHandler.new(options[:s3_upload_config])
      end

    output_manifest =
      manifest
      |> fetch_remote_files!(download_path, download_config)
      |> do_convert_manifest!(output_path, thumbnails_ctx)

    result_manifest =
      if upload_handler != nil do
        {ref, upload_handler} =
          output_manifest
          |> __MODULE__.Manifest.to_upload_handler_manifest()
          |> then(&S3.UploadHandler.spawn_task(upload_handler, &1))

        # FIXME: Add descriptive errors
        {:ok, upload_handler_result_manifest, _handler} =
          receive do
            {^ref, _res} = task_result ->
              S3.UploadHandler.process_result(upload_handler, task_result)
          end

        upload_handler_result_manifest
        |> __MODULE__.Manifest.from_upload_handler_manifest(output_manifest)
      else
        output_manifest
      end

    result_manifest
  end

  def convert_manifest!(_empty_manifest, _options), do: %{}

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
    Logger.info("Fetching file #{url}")

    with {:ok, bucket_name, s3_path} <- S3.Utils.parse_url(url),
         out_path <- Path.join(dl_path, Path.basename(s3_path)),
         {:ok, _result} <- S3.Utils.fetch_file(bucket_name, s3_path, out_path, dl_config) do
      {:ok, out_path}
    else
      # FIXME: Add descriptive errors
      _other -> :error
    end
  end

  defp do_convert_manifest!(manifest, output_path, thumbnails_ctx) do
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

    # FIXME: This won't work if we have audio/video only
    for {stream_id, %{video: video_files, audio: audio_files}} <- stream_map,
        {rid, %{filename: video_file, start_time: video_start}} <- video_files,
        {nil, %{filename: audio_file, start_time: audio_start}} <- audio_files,
        into: %{} do
      output_id = if rid == nil, do: stream_id, else: "#{stream_id}_#{rid}"
      output_file = Path.join(output_path, "#{output_id}.webm")

      FFmpeg.combine_av!(
        Path.join(output_path, video_file),
        video_start,
        Path.join(output_path, audio_file),
        audio_start,
        output_file
      )

      # TODO: Consider deleting the `.ivf` and `.ogg` files at this point

      stream_manifest = %{
        location: output_file,
        duration_seconds: FFmpeg.get_duration_in_seconds!(output_file)
      }

      stream_manifest =
        if thumbnails_ctx do
          thumbnail_file = FFmpeg.generate_thumbnail!(output_file, thumbnails_ctx)
          Map.put(stream_manifest, :thumbnail_location, thumbnail_file)
        else
          stream_manifest
        end

      {output_id, stream_manifest}
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

      # Returns the timestamp (in milliseconds) at which the first frame was received
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

    # Same behaviour as in `convert_video_track/4`
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
end
