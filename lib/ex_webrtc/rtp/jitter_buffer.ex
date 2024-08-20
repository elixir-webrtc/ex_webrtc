defmodule ExWebRTC.RTP.JitterBuffer do
  @moduledoc """
  Buffers and reorders RTP packets based on `sequence_number`, introducing controlled latency
  in order to combat network jitter and improve the QoS.
  """

  # Heavily inspired by:
  # https://github.com/membraneframework/membrane_rtp_plugin/blob/23f3279540aea7dea3a194fd5a1680c2549aebae/lib/membrane/rtp/jitter_buffer.ex

  use GenServer

  alias ExWebRTC.RTP.JitterBuffer.PacketStore

  @default_latency_ms 200

  @typedoc """
  Messages sent by the `#{inspect(__MODULE__)}` process to its controlling process.

  * `{:packet, packet}` - packet flushed from the buffer
  """
  @type message() :: {:jitter_buffer, pid(), {:packet, ExRTP.Packet.t()}}

  @typedoc """
  Options that can be passed to `#{inspect(__MODULE__)}.start_link/1`.

  * `controlling_process` - a pid of a process where all messages will be sent. `self()` by default.
  * `latency` - latency introduced by the buffer, in milliseconds. `#{@default_latency_ms}` by default.
  """
  @type options :: [{:controlling_process, Process.dest()}, {:latency, non_neg_integer()}]

  @doc """
  Starts a new `#{inspect(__MODULE__)}` process.

  `#{inspect(__MODULE__)}` is a `GenServer` under the hood, thus this function allows for
  passing the generic `t:GenServer.options/0` as an argument.

  Note: The buffer *won't* output any packets
  until `#{inspect(__MODULE__)}.start_timer/1` is called.
  """
  @spec start(options(), GenServer.options()) :: GenServer.on_start()
  def start(opts \\ [], gen_server_opts \\ []) do
    opts = Keyword.put_new(opts, :controlling_process, self())
    GenServer.start(__MODULE__, opts, gen_server_opts)
  end

  @doc """
  Starts and links to a new `#{inspect(__MODULE__)}` process.

  Works identically to `start/2`, but links to the calling process.
  """
  @spec start_link(options(), GenServer.options()) :: GenServer.on_start()
  def start_link(opts \\ [], gen_server_opts \\ []) do
    opts = Keyword.put_new(opts, :controlling_process, self())
    GenServer.start_link(__MODULE__, opts, gen_server_opts)
  end

  @doc """
  Starts the initial latency timer.

  The buffer will start to output packets `latency` milliseconds after this function is called.
  """
  @spec start_timer(GenServer.server()) :: :ok
  def start_timer(buffer) do
    GenServer.cast(buffer, :start_timer)
  end

  @doc """
  Places a packet in the JitterBuffer.

  Returns `:ok` even if the packet was rejected due to being late.
  """
  @spec place_packet(GenServer.server(), ExRTP.Packet.t()) :: :ok
  def place_packet(buffer, packet) do
    GenServer.cast(buffer, {:packet, packet})
  end

  @doc """
  Flushes all remaining packets and resets the JitterBuffer.

  After flushing, the rollover counter is set to `0` and the buffer *won't* output any packets
  until `#{inspect(__MODULE__)}.start_timer/1` is called again.
  """
  @spec flush(GenServer.server()) :: :ok
  def flush(buffer) do
    GenServer.cast(buffer, :flush)
  end

  @impl true
  def init(opts) do
    owner = Keyword.fetch!(opts, :controlling_process)
    latency = opts[:latency] || @default_latency_ms

    state = %{
      latency: latency,
      owner: owner,
      store: %PacketStore{},
      waiting?: true,
      max_latency_timer: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_cast(:start_timer, state) do
    Process.send_after(self(), :initial_latency_passed, state.latency)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:packet, packet}, state) do
    state =
      case PacketStore.insert_packet(state.store, packet) do
        {:ok, result} ->
          state = %{state | store: result}

          if state.waiting?, do: state, else: send_packets(state)

        {:error, :late_packet} ->
          state
      end

    {:noreply, state}
  end

  @impl true
  def handle_cast(:flush, %{store: store} = state) do
    store
    |> PacketStore.dump()
    |> Enum.each(&process_flushed_record(&1, state.owner))

    {:noreply, %{state | store: %PacketStore{}, waiting?: true}}
  end

  @impl true
  def handle_info(:initial_latency_passed, state) do
    state = %{state | waiting?: false} |> send_packets()
    {:noreply, state}
  end

  @impl true
  def handle_info(:send_packets, state) do
    state = %{state | max_latency_timer: nil} |> send_packets()
    {:noreply, state}
  end

  defp send_packets(%{store: store} = state) do
    # Flushes packets that stayed in queue longer than latency and any gaps before them
    {too_old_records, store} = PacketStore.flush_older_than(store, state.latency)
    # Additionally, flush packets as long as there are no gaps
    {gapless_records, store} = PacketStore.flush_ordered(store)

    Enum.each(too_old_records ++ gapless_records, &process_flushed_record(&1, state.owner))

    %{state | store: store} |> set_timer()
  end

  # TODO: nil -- missing packet (maybe owner should be notified about that)
  defp process_flushed_record(nil, _owner), do: :noop
  defp process_flushed_record(%{packet: packet}, owner), do: notify(owner, {:packet, packet})

  defp notify(owner, msg), do: send(owner, {:jitter_buffer, self(), msg})

  defp set_timer(%{max_latency_timer: nil, latency: latency} = state) do
    new_timer =
      case PacketStore.first_record_timestamp(state.store) do
        nil ->
          nil

        timestamp_ms ->
          since_insertion = System.monotonic_time(:millisecond) - timestamp_ms
          send_after_time = max(0, latency - since_insertion)

          Process.send_after(self(), :send_packets, send_after_time)
      end

    %{state | max_latency_timer: new_timer}
  end

  defp set_timer(%{max_latency_timer: timer} = state) when timer != nil, do: state
end
