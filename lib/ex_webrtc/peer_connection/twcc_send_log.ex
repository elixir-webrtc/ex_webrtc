defmodule ExWebRTC.PeerConnection.TWCCSendLog do
  @moduledoc false
  # Sender-side TWCC log.
  # Records departure timestamps and sizes for outgoing RTP packets
  # that carry a TWCC sequence number, allowing the end user to correlate
  # incoming TWCC feedback (TransportFeedback.CC) with send times.

  @packet_window_us 2_000_000

  @type t() :: %__MODULE__{
          packets: %{non_neg_integer() => {integer(), non_neg_integer()}},
          seq_no_queue: Qex.t()
        }

  defstruct packets: %{}, seq_no_queue: Qex.new()

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec record_packet(t(), non_neg_integer(), integer(), non_neg_integer()) :: t()
  def record_packet(log, seq_no, departure_time, size) do
    seq_no_queue = Qex.push(log.seq_no_queue, {seq_no, departure_time})
    packets = Map.put(log.packets, seq_no, {departure_time, size})

    {seq_no_queue, packets} = remove_old_packets(packets, seq_no_queue, departure_time)

    %__MODULE__{log | packets: packets, seq_no_queue: seq_no_queue}
  end

  @spec to_map(t()) :: %{non_neg_integer() => {integer(), non_neg_integer()}}
  def to_map(%__MODULE__{packets: packets}), do: packets

  defp remove_old_packets(packets, seq_no_queue, current_time) do
    min_time = current_time - @packet_window_us

    Enum.reduce_while(
      seq_no_queue,
      {seq_no_queue, packets},
      fn {seq_no, dep_time}, {seq_no_queue, packets} = acc ->
        if dep_time < min_time do
          {_, seq_no_queue} = Qex.pop!(seq_no_queue)
          packets = Map.delete(packets, seq_no)
          {:cont, {seq_no_queue, packets}}
        else
          {:halt, acc}
        end
      end
    )
  end
end
