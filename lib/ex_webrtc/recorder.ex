defmodule ExWebRTC.Recorder do
  @moduledoc """
  Saves received RTP packets to a file for later processing/analysis.

  Dumps raw RTP packets fed to it in a custom format. Use `Recorder.Converter` to process them.
  """

  use GenServer

  alias ExWebRTC.MediaStreamTrack

  require Logger

  @default_base_dir "./recordings"

  @typep track_manifest :: %{
           start_time: DateTime.t(),
           kind: :video | :audio,
           streams: [MediaStreamTrack.stream_id()],
           rid_map: %{MediaStreamTrack.rid() => integer()},
           location: String.t()
         }

  @opaque manifest :: %{MediaStreamTrack.id() => track_manifest()}

  @typedoc """
  Options that can be passed to `start_link/1`.

  * `base_dir` - Base directory where Recorder will save its artifacts. `#{@default_base_dir}` by default.
  * `on_start` - Callback that will be executed just after the Recorder is (re)started.
                 It should return the initial list of tracks to be added.
  * `s3_config` - WRITEME
  * `controlling_process` - WRITEME
  """
  @type option ::
          {:base_dir, String.t()}
          | {:on_start, (-> [MediaStreamTrack.t()])}
          | {:s3_config, keyword()}
          | {:controlling_process, Process.dest()}

  @type options :: [option()]

  # Necessary to start Recorder under a supervisor using `{Recorder, [recorder_opts, gen_server_opts]}`
  @doc false
  @spec child_spec(list()) :: Supervisor.child_spec()
  def child_spec(args) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, args}
    }
  end

  @doc """
  Starts a new `ExWebRTC.Recorder` process.

  `ExWebRTC.Recorder` is a `GenServer` under the hood, thus this function allows for
  passing the generic `t:GenServer.options/0` as an argument.
  """
  @spec start(options(), GenServer.options()) :: GenServer.on_start()
  def start(recorder_opts \\ [], gen_server_opts \\ []) do
    config =
      recorder_opts
      |> Keyword.put_new(:controlling_process, self())

    # |> to_config?

    GenServer.start(__MODULE__, config, gen_server_opts)
  end

  @doc """
  Starts a new `ExWebRTC.Recorder` process.

  Works identically to `start/2`, but links to the calling process.
  """
  @spec start_link(options(), GenServer.options()) :: GenServer.on_start()
  def start_link(recorder_opts \\ [], gen_server_opts \\ []) do
    config =
      recorder_opts
      |> Keyword.put_new(:controlling_process, self())

    # |> to_config?

    GenServer.start_link(__MODULE__, config, gen_server_opts)
  end

  @doc """
  Adds new tracks to the recording.
  """
  @spec add_tracks(GenServer.server(), [MediaStreamTrack.t()]) :: {:ok, manifest()}
  def add_tracks(recorder, tracks) do
    GenServer.call(recorder, {:add_tracks, tracks})
  end

  @doc """
  Records a received packet on the given track.
  """
  @spec record(
          GenServer.server(),
          MediaStreamTrack.id(),
          MediaStreamTrack.rid() | nil,
          ExRTP.Packet.t()
        ) :: :ok
  def record(recorder, track_id, rid, %ExRTP.Packet{} = packet) do
    recv_time = System.monotonic_time(:millisecond)
    GenServer.cast(recorder, {:record, track_id, rid, recv_time, packet})
  end

  @doc """
  # WRITEME
  Changes the controlling process of this `peer_connection` process.

  Controlling process is a process that receives all of the messages (described
  by `t:message/0`) from this PeerConnection.
  """
  @spec controlling_process(GenServer.server(), Process.dest()) :: :ok
  def controlling_process(recorder, controlling_process) do
    GenServer.call(recorder, {:controlling_process, controlling_process})
  end

  @doc """
  WRITEME Adds new tracks to the recording.
  """
  @spec end_tracks(GenServer.server(), [MediaStreamTrack.id()]) ::
          {:ok, manifest(), reference() | nil} | {:error, :tracks_not_found}
  def end_tracks(recorder, track_ids) do
    GenServer.call(recorder, {:end_tracks, track_ids})
  end

  @impl true
  def init(config) do
    base_dir =
      (config[:base_dir] || @default_base_dir)
      |> Path.join(current_datetime())
      |> Path.expand()

    :ok = File.mkdir_p!(base_dir)
    Logger.info("Starting recorder. Recordings will be saved under: #{base_dir}")

    upload_handler =
      if config[:s3_config] do
        Logger.info("Recordings will be uploaded to S3 WRITEME")
        __MODULE__.S3.UploadHandler.new(config[:s3_config])
      end

    state = %{
      owner: config[:controlling_process],
      base_dir: base_dir,
      manifest_path: Path.join(base_dir, "manifest.json"),
      track_data: %{},
      upload_handler: upload_handler
    }

    case config[:on_start] do
      nil ->
        {:ok, state}

      callback ->
        {:ok, state, {:continue, {:on_start, callback}}}
    end
  end

  @impl true
  def handle_continue({:on_start, on_start}, state) do
    case on_start.() do
      [] ->
        {:noreply, state}

      tracks ->
        {_manifest_diff, state} = do_add_tracks(tracks, state)
        {:noreply, state}
    end
  end

  @impl true
  def handle_call({:controlling_process, controlling_process}, _from, state) do
    state = %{state | owner: controlling_process}
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:add_tracks, tracks}, _from, state) do
    {manifest_diff, state} = do_add_tracks(tracks, state)
    {:reply, {:ok, manifest_diff}, state}
  end

  @impl true
  def handle_call({:end_tracks, track_ids}, _from, state) do
    case Enum.filter(track_ids, &Map.has_key?(state.track_data, &1)) do
      [] ->
        {:reply, {:error, :tracks_not_found}, state}

      track_ids ->
        {manifest_diff, ref, state} = do_end_tracks(track_ids, state)
        {:reply, {:ok, manifest_diff, ref}, state}
    end
  end

  @impl true
  def handle_cast({:record, track_id, rid, recv_time, packet}, state)
      when is_map_key(state.track_data, track_id) do
    %{file: file, rid_map: rid_map} = state.track_data[track_id]

    with {:ok, rid_idx} <- Map.fetch(rid_map, rid),
         false <- is_nil(file) do
      :ok = IO.binwrite(file, serialize_packet(packet, rid_idx, recv_time))
    else
      :error ->
        Logger.warning("""
        Tried to save packet for unknown rid. Ignoring. Track id: #{inspect(track_id)}, rid: #{inspect(rid)}.\
        """)

      true ->
        Logger.warning("""
        Tried to save packet for track which has been ended. Ignoring. Track id: #{inspect(track_id)} \
        """)
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:record, track_id, _rid, _recv_time, _packet}, state) do
    Logger.warning("""
    Tried to save packet for unknown track id. Ignoring. Track id: #{inspect(track_id)}.\
    """)

    {:noreply, state}
  end

  @impl true
  def handle_info({ref, _res} = task_result, state) when is_reference(ref) do
    if state.upload_handler do
      {result, manifest, handler} =
        __MODULE__.S3.UploadHandler.process_result(state.upload_handler, task_result)

      case result do
        :ok ->
          send(state.owner, {:ex_webrtc_recorder, self(), {:upload_complete, ref, manifest}})

        {:error, :upload_failed} ->
          send(state.owner, {:ex_webrtc_recorder, self(), {:upload_failed, ref, manifest}})

        {:error, :unknown_task} ->
          raise "Upload handler encountered result of unknown task"
      end

      {:noreply, %{state | upload_handler: handler}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp do_add_tracks(tracks, state) do
    start_time = DateTime.utc_now()

    new_track_data =
      Map.new(tracks, fn track ->
        file_path = Path.join(state.base_dir, "#{track.id}.rtpx")

        track_entry = %{
          start_time: start_time,
          kind: track.kind,
          streams: track.streams,
          rid_map: (track.rids || [nil]) |> Enum.with_index() |> Map.new(),
          location: file_path,
          file: File.open!(file_path, [:write])
        }

        {track.id, track_entry}
      end)

    manifest_diff = to_manifest(new_track_data)

    state = %{state | track_data: Map.merge(state.track_data, new_track_data)}

    :ok = File.write!(state.manifest_path, state.track_data |> to_manifest() |> Jason.encode!())

    {manifest_diff, state}
  end

  defp do_end_tracks(track_ids, state) do
    state =
      Enum.reduce(track_ids, state, fn track_id, state ->
        %{file: file} = state.track_data[track_id]
        File.close(file)

        put_in(state, [:track_data, track_id, :file], nil)
      end)

    manifest_diff = to_manifest(state.track_data, track_ids)

    case state.upload_handler do
      nil ->
        {manifest_diff, nil, state}

      handler ->
        {ref, handler} = __MODULE__.S3.UploadHandler.spawn_task(handler, manifest_diff)

        {manifest_diff, ref, %{state | upload_handler: handler}}
    end
  end

  defp to_manifest(track_data, track_ids) do
    track_data |> Map.take(track_ids) |> to_manifest()
  end

  defp to_manifest(track_data) do
    Map.new(track_data, fn {id, track} ->
      {id, Map.delete(track, :file)}
    end)
  end

  defp serialize_packet(packet, rid_idx, recv_time) do
    packet = ExRTP.Packet.encode(packet)
    packet_size = byte_size(packet)
    <<rid_idx::8, recv_time::64, packet_size::32, packet::binary>>
  end

  defp current_datetime() do
    {{y, mo, d}, {h, m, s}} = :calendar.local_time()

    # e.g. 20240130-120315
    :io_lib.format("~4..0w~2..0w~2..0w-~2..0w~2..0w~2..0w", [y, mo, d, h, m, s])
    |> to_string()
  end
end
