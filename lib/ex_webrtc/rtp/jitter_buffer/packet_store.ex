defmodule ExWebRTC.RTP.JitterBuffer.PacketStore do
  @moduledoc false

  # Store for RTP packets. Packets are stored in `Heap` ordered by packet index. Packet index is
  # defined in RFC 3711 (SRTP) as: 2^16 * rollover count + sequence number.

  import Bitwise

  alias ExWebRTC.RTP.JitterBuffer.Heap

  defmodule Entry do
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
    Compares two entries.

    Returns true if the first entry is older than the second one.
    """
    @spec comparator(t(), t()) :: boolean()
    # Designed to be used with `JitterBuffer.Heap`
    def comparator(%__MODULE__{index: l_index}, %__MODULE__{index: r_index}),
      do: l_index < r_index
  end

  @seq_number_limit bsl(1, 16)

  defstruct flush_index: nil,
            highest_incoming_index: nil,
            heap: Heap.new(&Entry.comparator/2),
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
  - `heap` - contains entries containing packets
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
  @spec insert(t(), ExRTP.Packet.t()) :: {:ok, t()} | {:error, :late_packet}
  def insert(store, %{sequence_number: seq_num} = packet) do
    do_insert_packet(store, packet, seq_num)
  end

  defp do_insert_packet(%__MODULE__{flush_index: nil} = store, packet, 0) do
    store = add_entry(store, Entry.new(packet, @seq_number_limit), :next)
    {:ok, %__MODULE__{store | flush_index: @seq_number_limit - 1}}
  end

  defp do_insert_packet(%__MODULE__{flush_index: nil} = store, packet, seq_num) do
    store = add_entry(store, Entry.new(packet, seq_num), :current)
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

    if index > flush_index do
      entry = Entry.new(packet, index)
      {:ok, add_entry(store, entry, rollover)}
    else
      {:error, :late_packet}
    end
  end

  @doc """
  Flushes the store until the first gap in sequence numbers of entries
  """
  @spec flush_ordered(t()) :: {[ExRTP.Packet.t() | nil], t()}
  def flush_ordered(store) do
    flush_while(store, fn %__MODULE__{flush_index: flush_index}, %Entry{index: index} ->
      index == flush_index + 1
    end)
  end

  @doc """
  Flushes the store as long as it contains a packet with the timestamp older than provided duration
  """
  @spec flush_older_than(t(), non_neg_integer()) :: {[ExRTP.Packet.t() | nil], t()}
  def flush_older_than(store, max_age_ms) do
    max_age_timestamp = System.monotonic_time(:millisecond) - max_age_ms

    flush_while(store, fn _store, %Entry{timestamp_ms: timestamp} ->
      timestamp <= max_age_timestamp
    end)
  end

  @doc """
  Returns all packets that are stored in the `PacketStore`.
  """
  @spec dump(t()) :: [ExRTP.Packet.t() | nil]
  def dump(%__MODULE__{} = store) do
    {packets, _store} = flush_while(store, fn _store, _entry -> true end)
    packets
  end

  @doc """
  Returns timestamp (time of insertion) of the packet with the lowest index
  """
  @spec first_packet_timestamp(t()) :: integer() | nil
  def first_packet_timestamp(%__MODULE__{heap: heap}) do
    case Heap.root(heap) do
      %Entry{timestamp_ms: time} -> time
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

  @doc false
  @spec flush_one(t()) :: {Entry.t() | nil, t()}
  # Flushes the store to the packet with the next sequence number.
  #
  # If this packet is present, it will be returned.
  # Otherwise it will be treated as late and rejected on attempt to insert into the store.
  #
  # Should be called directly only when testing this module
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

  defp flush_while(%__MODULE__{heap: heap} = store, fun, acc \\ []) do
    heap
    |> Heap.root()
    |> case do
      nil ->
        {Enum.reverse(acc), store}

      entry ->
        if fun.(store, entry) do
          {entry, store} = flush_one(store)
          packet = get_packet(entry)
          flush_while(store, fun, [packet | acc])
        else
          {Enum.reverse(acc), store}
        end
    end
  end

  defp add_entry(%__MODULE__{heap: heap, set: set} = store, %Entry{} = entry, entry_rollover) do
    if set |> MapSet.member?(entry.index) do
      store
    else
      %__MODULE__{store | heap: Heap.push(heap, entry), set: MapSet.put(set, entry.index)}
      |> update_highest_incoming_index(entry.index)
      |> update_roc(entry_rollover)
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

  defp update_roc(store, _entry_rollover), do: store

  defp get_packet(nil), do: nil
  defp get_packet(entry), do: entry.packet
end
