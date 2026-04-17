defmodule ExWebRTC.PeerConnection.TWCCSendLog do
  @moduledoc false
  # Sender-side TWCC log.
  # Records departure timestamps and sizes for outgoing RTP packets
  # that carry a TWCC sequence number, allowing the end user to correlate
  # incoming TWCC feedback (TransportFeedback.CC) with send times.

  @packet_window_us 2_000_000

  @type t() :: %__MODULE__{
          packets: %{non_neg_integer() => {integer(), non_neg_integer()}}
        }

  defstruct packets: %{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec record_packet(t(), non_neg_integer(), integer(), non_neg_integer()) :: t()
  def record_packet(log, seq_no, departure_time, size) do
    packets =
      log.packets
      |> Map.put(seq_no, {departure_time, size})
      |> remove_old_packets(departure_time)

    %__MODULE__{log | packets: packets}
  end

  @spec to_map(t()) :: %{non_neg_integer() => {integer(), non_neg_integer()}}
  def to_map(%__MODULE__{packets: packets}), do: packets

  defp remove_old_packets(packets, current_time) do
    min_time = current_time - @packet_window_us

    Map.filter(packets, fn {_seq_no, {departure_time, _size}} ->
      departure_time >= min_time
    end)
  end
end
