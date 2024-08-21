defmodule ExWebRTC.RTP.JitterBuffer do
  @moduledoc """
  Buffers and reorders RTP packets based on `sequence_number`, introducing controlled latency
  in order to combat network jitter and improve the QoS.
  """

  # Heavily inspired by:
  # https://github.com/membraneframework/membrane_rtp_plugin/blob/23f3279540aea7dea3a194fd5a1680c2549aebae/lib/membrane/rtp/jitter_buffer.ex

  alias ExWebRTC.RTP.JitterBuffer.PacketStore
  alias ExRTP.Packet

  @default_latency_ms 200

  @typedoc """
  Options that can be passed to `new/1`.

  * `latency` - latency introduced by the buffer, in milliseconds. `#{@default_latency_ms}` by default.
  """
  @type options :: [latency: non_neg_integer()]

  @typedoc """
  Time (in milliseconds) after which `handle_timer/1` should be called.
  Can be `nil`, in which case no timer needs to be set.
  """
  @type timer :: non_neg_integer() | nil

  @typedoc """
  The 3-element tuple returned by all functions other than `new/1`.

  * `buffer` - `t:#{inspect(__MODULE__)}.t/0`.
  * `packets` - a list with packets flushed from the buffer as a result of the function call. May be empty.
  * `timer_duration_ms` - see `t:timer/0`.

  Generally speaking, all results of this type can be handled in the same way.
  """
  @type result :: {buffer :: t(), packets :: [Packet.t()], timer_duration_ms :: timer()}

  @opaque t :: %__MODULE__{
            latency: non_neg_integer(),
            store: PacketStore.t(),
            state: :initial_wait | :timer_set | :timer_not_set
          }

  @enforce_keys [:latency]
  defstruct @enforce_keys ++
              [
                store: %PacketStore{},
                state: :initial_wait
              ]

  @doc """
  Creates a new `t:#{inspect(__MODULE__)}.t/0`.
  """
  @spec new(options()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      latency: opts[:latency] || @default_latency_ms
    }
  end

  @doc """
  Places a packet in the JitterBuffer.

  Note: The initial latency timer will be set after the first packet is inserted into the buffer.
  If you want to start it at your own discretion, schedule a `handle_timer/1` call prior to that.
  """
  @spec place_packet(t(), Packet.t()) :: result()
  def place_packet(buffer, packet)

  def place_packet(%{state: :initial_wait} = buffer, packet) do
    {buffer, timer} = maybe_set_timer(buffer)
    {_result, buffer} = try_insert_packet(buffer, packet)

    {buffer, [], timer}
  end

  def place_packet(buffer, packet) do
    case try_insert_packet(buffer, packet) do
      {:ok, buffer} -> send_packets(buffer)
      {:error, buffer} -> {buffer, [], nil}
    end
  end

  @doc """
  Flushes all remaining packets and resets the JitterBuffer.

  Note: After flushing, the rollover counter is reset to `0`.
  """
  @spec flush(t()) :: result()
  def flush(buffer) do
    packets =
      buffer.store
      |> PacketStore.dump()
      |> records_to_packets()

    {%__MODULE__{latency: buffer.latency}, packets, nil}
  end

  @doc """
  Handles the end of a previously set timer.
  """
  @spec handle_timer(t()) :: result()
  def handle_timer(buffer) do
    %__MODULE__{buffer | state: :timer_not_set} |> send_packets()
  end

  @spec try_insert_packet(t(), Packet.t()) :: {:ok | :error, t()}
  defp try_insert_packet(buffer, packet) do
    case PacketStore.insert_packet(buffer.store, packet) do
      {:ok, store} -> {:ok, %__MODULE__{buffer | store: store}}
      {:error, :late_packet} -> {:error, buffer}
    end
  end

  @spec send_packets(t()) :: result()
  defp send_packets(%{store: store} = buffer) do
    # Flush packets that stayed in queue longer than latency and any gaps before them
    {too_old_records, store} = PacketStore.flush_older_than(store, buffer.latency)
    # Additionally, flush packets as long as there are no gaps
    {gapless_records, store} = PacketStore.flush_ordered(store)

    packets =
      too_old_records
      |> Stream.concat(gapless_records)
      |> records_to_packets()

    {buffer, timer} = maybe_set_timer(%__MODULE__{buffer | store: store})

    {buffer, packets, timer}
  end

  @spec records_to_packets(Enumerable.t(PacketStore.Record.t())) :: [Packet.t()]
  defp records_to_packets(records) do
    records
    # TODO: nil -- missing packet (maybe owner should be notified about that)
    |> Stream.reject(&is_nil/1)
    |> Enum.map(& &1.packet)
  end

  @spec maybe_set_timer(t()) :: {t(), timer()}
  defp maybe_set_timer(buffer)

  defp maybe_set_timer(%{state: :initial_wait} = buffer) do
    case PacketStore.first_record_timestamp(buffer.store) do
      # If we're inserting the very first packet, set the initial latency timer
      nil -> {buffer, buffer.latency}
      _ts -> {buffer, nil}
    end
  end

  defp maybe_set_timer(%{state: :timer_not_set} = buffer) do
    case PacketStore.first_record_timestamp(buffer.store) do
      nil ->
        {buffer, nil}

      timestamp_ms ->
        since_insertion = System.monotonic_time(:millisecond) - timestamp_ms
        send_after_time = max(0, buffer.latency - since_insertion)

        {%__MODULE__{buffer | state: :timer_set}, send_after_time}
    end
  end

  defp maybe_set_timer(%{state: :timer_set} = buffer), do: {buffer, nil}
end
