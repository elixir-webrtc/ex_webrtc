defmodule ExWebRTC.PeerConnection.TWCCRecorder do
  @moduledoc false
  # inspired by Pion's TWCC interceptor https://github.com/pion/interceptor/tree/master/pkg/twcc
  # and chrome's implementation https://source.chromium.org/chromium/chromium/src/+/main:third_party/webrtc/modules/remote_bitrate_estimator/remote_estimator_proxy.cc;l=276;drc=b5cd13bb6d5d157a5fbe3628b2dd1c1e106203c6;bpv=0

  import Bitwise

  alias ExRTCP.Packet.TransportFeedback.CC

  @max_seq_num 0xFFFF
  @breakpoint 0x7FFF
  @packet_window 500

  @type t() :: %__MODULE__{
          base_seq_no: non_neg_integer() | nil,
          start_seq_no: non_neg_integer() | nil,
          end_seq_no: non_neg_integer() | nil,
          timestamps: %{non_neg_integer() => float()}
        }

  # start, base - inclusive, end - exclusive
  # start, end - actual range where map values might be set
  # base - from where packets should be added to next feedback
  # if end_seq_no >= start_seq_no, then no packets are available
  defstruct base_seq_no: nil,
            start_seq_no: nil,
            end_seq_no: nil,
            timestamps: %{}

  @spec record_packet(t(), non_neg_integer()) :: t()
  def record_packet(%{base_seq_no: nil, start_seq_no: nil, end_seq_no: nil}, seq_no) do
    # initial case
    timestamp = get_time()

    %{
      base_seq_no: seq_no,
      start_seq_no: seq_no,
      end_seq_no: seq_no + 1,
      timestamps: %{seq_no => timestamp}
    }
  end

  def record_packet(recorder, raw_seq_no) do
    timestamp = get_time()

    %{
      base_seq_no: base_seq_no,
      start_seq_no: start_seq_no,
      end_seq_no: end_seq_no,
      timestamps: timestamps
    } = recorder

    seq_no = unroll(raw_seq_no, end_seq_no)

    # dont overwrite timestamps already present in the map, unless we already
    # included them in a feedback (maybe we shouldn't at all?)
    timestamps =
      if seq_no < base_seq_no do
        Map.put(timestamps, seq_no, timestamp)
      else
        Map.put_new(timestamps, seq_no, timestamp)
      end

    base_seq_no = if seq_no < base_seq_no, do: seq_no, else: base_seq_no

    {start_seq_no, end_seq_no} =
      cond do
        seq_no < start_seq_no -> {seq_no, end_seq_no}
        seq_no >= end_seq_no -> {start_seq_no, seq_no + 1}
        true -> {start_seq_no, end_seq_no}
      end

    %__MODULE__{
      base_seq_no: base_seq_no,
      start_seq_no: start_seq_no,
      end_seq_no: end_seq_no,
      timestamps: timestamps
    }
    |> remove_old_packets(timestamp)
  end

  defp get_time, do: System.monotonic_time(:microsecond) / 1000

  defp unroll(seq_no, end_seq_no) do
    # internally, we dont wrap the sequence number around 2^16
    # so when receiving a new seq_num, we have to "unroll" it
    end_rolled = roll(end_seq_no)
    delta = seq_no - end_rolled

    delta =
      cond do
        delta in -@breakpoint..@breakpoint -> delta
        delta < -@breakpoint -> delta + @max_seq_num + 1
        delta > @breakpoint -> delta - @max_seq_num - 1
      end

    end_seq_no + delta
  end

  defp roll(seq_no), do: seq_no &&& @max_seq_num

  defp remove_old_packets(recorder, cur_timestamp) do
    %{
      base_seq_no: base_seq_no,
      start_seq_no: start_seq_no,
      end_seq_no: end_seq_no,
      timestamps: timestamps
    } = recorder

    min_timestamp = cur_timestamp - @packet_window

    last_old =
      Enum.reduce_while(start_seq_no..(end_seq_no - 1), nil, fn i, last_old ->
        case Map.fetch(timestamps, i) do
          {:ok, timestamp} when timestamp < min_timestamp -> {:cont, i}
          {:ok, _timestamp} -> {:halt, last_old}
          :error -> {:cont, last_old}
        end
      end)

    if is_nil(last_old) do
      recorder
    else
      timestamps =
        Enum.reduce(start_seq_no..last_old, timestamps, fn i, timestamps ->
          Map.delete(timestamps, i)
        end)

      start_seq_no = last_old + 1

      base_seq_no = if start_seq_no > base_seq_no, do: start_seq_no, else: base_seq_no

      %__MODULE__{
        base_seq_no: base_seq_no,
        start_seq_no: start_seq_no,
        end_seq_no: end_seq_no,
        timestamps: timestamps
      }
    end
  end

  @spec get_feedback(t()) :: {:ok, t(), CC.t()} | {:error, :no_packets_available}
  def get_feedback(%{base_seq_no: base_seq_no, end_seq_no: end_seq_no})
      when base_seq_no >= end_seq_no,
      do: {:error, :no_packets_available}

  def get_feedback(_recorder) do
    # TODO: add comment why we don't remove sent packets here
  end
end
