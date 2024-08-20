defmodule ExWebRTC.RTP.JitterBuffer.PacketStore do
  @moduledoc false

  # Store for RTP packets. Packets are stored in `Heap` ordered by packet index. Packet index is
  # defined in RFC 3711 (SRTP) as: 2^16 * rollover count + sequence number.

  import Bitwise

  defmodule Record do
    @moduledoc false
    # Describes a structure that is stored in the PacketStore.

    @enforce_keys [:index, :timestamp_ms, :packet]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            index: non_neg_integer(),
            timestamp_ms: integer(),
            packet: ExRTP.Packet.t()
          }

    @spec new(ExRTP.Packet.t(), non_neg_integer()) :: t()
    def new(packet, index) do
      %__MODULE__{
        index: index,
        timestamp_ms: System.monotonic_time(:millisecond),
        packet: packet
      }
    end

    @doc """
    Compares two records.

    Returns true if the first record is older than the second one.
    """
    @spec comparator(t(), t()) :: boolean()
    # Designed to be used with Heap: https://gitlab.com/jimsy/heap/blob/master/lib/heap.ex#L71
    def comparator(%__MODULE__{index: l_index}, %__MODULE__{index: r_index}),
      do: l_index < r_index
  end

  @seq_number_limit bsl(1, 16)

  defstruct flush_index: nil,
            highest_incoming_index: nil,
            heap: Heap.new(&Record.comparator/2),
            set: MapSet.new(),
            rollover_count: 0

  @typedoc """
  Type describing PacketStore structure.

  Fields:
  - `flush_index` - index of the last packet that has been emitted (or would have been
  emitted, but never arrived) as a result of a call to one of the `flush` functions
  - `highest_incoming_index` - the highest index in the buffer so far, mapping to the most recently produced
  RTP packet placed in JitterBuffer
  - `rollover_count` - count of all performed rollovers (cycles of sequence number)
  - `heap` - contains records containing packets
  - `set` - helper structure for faster read operations; content is the same as in `heap`
  """
  @type t :: %__MODULE__{
          flush_index: non_neg_integer() | nil,
          highest_incoming_index: non_neg_integer() | nil,
          heap: Heap.t(),
          set: MapSet.t(),
          rollover_count: non_neg_integer()
        }

  @doc """
  Inserts a packet into the Store.

  Each subsequent packet must have sequence number greater than the previously returned
  one or be part of a rollover.
  """
  @spec insert_packet(t(), ExRTP.Packet.t()) :: {:ok, t()} | {:error, :late_packet}
  def insert_packet(store, %{sequence_number: seq_num} = packet) do
    do_insert_packet(store, packet, seq_num)
  end

  defp do_insert_packet(%__MODULE__{flush_index: nil} = store, packet, 0) do
    store = add_record(store, Record.new(packet, @seq_number_limit), :next)
    {:ok, %__MODULE__{store | flush_index: @seq_number_limit - 1}}
  end

  defp do_insert_packet(%__MODULE__{flush_index: nil} = store, packet, seq_num) do
    store = add_record(store, Record.new(packet, seq_num), :current)
    {:ok, %__MODULE__{store | flush_index: seq_num - 1}}
  end

  defp do_insert_packet(
         %__MODULE__{
           flush_index: flush_index,
           highest_incoming_index: highest_incoming_index,
           rollover_count: roc
         } = store,
         packet,
         seq_num
       ) do
    highest_seq_num = rem(highest_incoming_index, @seq_number_limit)

    {rollover, index} =
      case from_which_rollover(highest_seq_num, seq_num, @seq_number_limit) do
        :current -> {:current, seq_num + roc * @seq_number_limit}
        :previous -> {:previous, seq_num + (roc - 1) * @seq_number_limit}
        :next -> {:next, seq_num + (roc + 1) * @seq_number_limit}
      end

    if fresh_packet?(flush_index, index) do
      record = Record.new(packet, index)
      {:ok, add_record(store, record, rollover)}
    else
      {:error, :late_packet}
    end
  end

  @doc """
  Flushes the store to the packet with the next sequence number.

  If this packet is present, it will be returned.
  Otherwise it will be treated as late and rejected on attempt to insert into the store.
  """
  @spec flush_one(t()) :: {Record.t() | nil, t()}
  def flush_one(store)

  def flush_one(%__MODULE__{flush_index: nil} = store) do
    {nil, store}
  end

  def flush_one(%__MODULE__{flush_index: flush_index, heap: heap, set: set} = store) do
    record = Heap.root(heap)

    expected_next_index = flush_index + 1

    {result, store} =
      if record != nil and record.index == expected_next_index do
        updated_heap = Heap.pop(heap)
        updated_set = MapSet.delete(set, record.index)

        updated_store = %__MODULE__{store | heap: updated_heap, set: updated_set}

        {record, updated_store}
      else
        # TODO: instead of nil use expected_next_index to notify owner about missing packet
        {nil, store}
      end

    {result, %__MODULE__{store | flush_index: expected_next_index}}
  end

  @doc """
  Flushes the store until the first gap in sequence numbers of records
  """
  @spec flush_ordered(t()) :: {[Record.t() | nil], t()}
  def flush_ordered(store) do
    flush_while(store, fn %__MODULE__{flush_index: flush_index}, %Record{index: index} ->
      index == flush_index + 1
    end)
  end

  @doc """
  Flushes the store as long as it contains a packet with the timestamp older than provided duration
  """
  @spec flush_older_than(t(), non_neg_integer()) :: {[Record.t() | nil], t()}
  def flush_older_than(store, max_age_ms) do
    max_age_timestamp = System.monotonic_time(:millisecond) - max_age_ms

    flush_while(store, fn _store, %Record{timestamp_ms: timestamp} ->
      timestamp <= max_age_timestamp
    end)
  end

  @doc """
  Returns all packets that are stored in the `PacketStore`.
  """
  @spec dump(t()) :: [Record.t() | nil]
  def dump(%__MODULE__{} = store) do
    {records, _store} = flush_while(store, fn _store, _record -> true end)
    records
  end

  @doc """
  Returns timestamp (time of insertion) of the packet with the lowest index
  """
  @spec first_record_timestamp(t()) :: integer() | nil
  def first_record_timestamp(%__MODULE__{heap: heap}) do
    case Heap.root(heap) do
      %Record{timestamp_ms: time} -> time
      nil -> nil
    end
  end

  @spec from_which_rollover(number() | nil, number(), number()) :: :current | :previous | :next
  def from_which_rollover(previous_value, new_value, rollover_length)

  def from_which_rollover(nil, _new, _rollover_length), do: :current

  def from_which_rollover(previous_value, new_value, rollover_length) do
    # a) current rollover
    distance_if_current = abs(previous_value - new_value)
    # b) new_value is from the previous rollover
    distance_if_previous = abs(previous_value - (new_value - rollover_length))
    # c) new_value is in the next rollover
    distance_if_next = abs(previous_value - (new_value + rollover_length))

    [
      {:current, distance_if_current},
      {:previous, distance_if_previous},
      {:next, distance_if_next}
    ]
    |> Enum.min_by(fn {_atom, distance} -> distance end)
    |> then(fn {result, _value} -> result end)
  end

  defp fresh_packet?(flush_index, index), do: index > flush_index

  defp flush_while(%__MODULE__{heap: heap} = store, fun, acc \\ []) do
    heap
    |> Heap.root()
    |> case do
      nil ->
        {Enum.reverse(acc), store}

      record ->
        if fun.(store, record) do
          {record, store} = flush_one(store)
          flush_while(store, fun, [record | acc])
        else
          {Enum.reverse(acc), store}
        end
    end
  end

  defp add_record(%__MODULE__{heap: heap, set: set} = store, %Record{} = record, record_rollover) do
    if set |> MapSet.member?(record.index) do
      store
    else
      %__MODULE__{store | heap: Heap.push(heap, record), set: MapSet.put(set, record.index)}
      |> update_highest_incoming_index(record.index)
      |> update_roc(record_rollover)
    end
  end

  defp update_highest_incoming_index(
         %__MODULE__{highest_incoming_index: last} = store,
         added_index
       )
       when added_index > last or last == nil,
       do: %__MODULE__{store | highest_incoming_index: added_index}

  defp update_highest_incoming_index(
         %__MODULE__{highest_incoming_index: last} = store,
         added_index
       )
       when last >= added_index,
       do: store

  defp update_roc(%{rollover_count: roc} = store, :next),
    do: %__MODULE__{store | rollover_count: roc + 1}

  defp update_roc(store, _record_rollover), do: store
end
