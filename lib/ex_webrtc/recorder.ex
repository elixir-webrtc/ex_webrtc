defmodule ExWebRTC.Recorder do
  @moduledoc """
  Saves received RTP packets to a file for later processing/analysis.

  Dumps raw RTP packets fed to it in a custom format. Use `Recorder.Converter` to process them.
  """

  use GenServer

  alias ExWebRTC.MediaStreamTrack

  require Logger

  @default_base_dir "./recordings"

  @typedoc """
  Options that can be passed to `start_link/1`.

  * `base_dir` - Base directory where Recorder will save its artifacts. `#{@default_base_dir}` by default.
  * `on_start` - Callback that will be executed just after the Recorder is (re)started.
                 It should return the initial list of tracks to be added.
  """
  @type option ::
          {:base_dir, String.t()}
          | {:on_start, (-> [MediaStreamTrack.t()])}

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
    GenServer.start(__MODULE__, recorder_opts, gen_server_opts)
  end

  @doc """
  Starts a new `ExWebRTC.Recorder` process.

  Works identically to `start/2`, but links to the calling process.
  """
  @spec start_link(options(), GenServer.options()) :: GenServer.on_start()
  def start_link(recorder_opts \\ [], gen_server_opts \\ []) do
    GenServer.start_link(__MODULE__, recorder_opts, gen_server_opts)
  end

  @doc """
  Adds new tracks to the recording.
  """
  @spec add_tracks(GenServer.server(), [MediaStreamTrack.t()]) :: :ok
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

  @impl true
  def init(config) do
    base_dir =
      (config[:base_dir] || @default_base_dir)
      |> Path.join(current_datetime())
      |> Path.expand()

    :ok = File.mkdir_p!(base_dir)
    Logger.info("Starting recorder. Recordings will be saved under: #{base_dir}")

    state = %{
      base_dir: base_dir,
      tracks: %{}
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
        state = do_add_tracks(tracks, state)
        {:noreply, state}
    end
  end

  @impl true
  def handle_call({:add_tracks, tracks}, _from, state) do
    state = do_add_tracks(tracks, state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:record, track_id, rid, recv_time, packet}, state)
      when is_map_key(state.tracks, track_id) do
    %{file: file, rid_map: rid_map} = state.tracks[track_id]

    case rid_map do
      %{^rid => rid_idx} ->
        :ok = IO.binwrite(file, serialize_packet(packet, rid_idx, recv_time))

      _other ->
        Logger.warning("""
        Tried to save packet for unknown rid. Ignoring. Track id: #{inspect(track_id)}, rid: #{inspect(rid)}.\
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
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp do_add_tracks(tracks, state) do
    start_time = DateTime.utc_now()

    tracks =
      Map.new(tracks, fn track ->
        path = Path.join(state.base_dir, "#{track.id}.rtpx")
        file = File.open!(path, [:write])
        rid_map = (track.rids || [nil]) |> Enum.with_index() |> Map.new()

        {track.id,
         %{kind: track.kind, rid_map: rid_map, path: path, file: file, start_time: start_time}}
      end)

    state = %{state | tracks: Map.merge(state.tracks, tracks)}
    report_path = Path.join(state.base_dir, "report.json")

    report =
      Map.new(state.tracks, fn {id, track} ->
        track = Map.delete(track, :file)
        {id, track}
      end)

    :ok = File.write!(report_path, Jason.encode!(report))

    state
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
