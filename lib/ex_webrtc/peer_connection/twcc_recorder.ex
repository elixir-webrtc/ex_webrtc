defmodule ExWebRTC.PeerConnection.TWCCRecorder do
  @moduledoc false
  # inspired by Pion's TWCC interceptor https://github.com/pion/interceptor/tree/master/pkg/twcc
  # and chrome's implementation https://source.chromium.org/chromium/chromium/src/+/main:third_party/webrtc/modules/remote_bitrate_estimator/remote_estimator_proxy.cc;l=276;drc=b5cd13bb6d5d157a5fbe3628b2dd1c1e106203c6;bpv=0

  defmodule Timer do
    @moduledoc false

    @opaque t() :: %__MODULE__{base: non_neg_integer()}

    @enforce_keys [:base]
    defstruct @enforce_keys

    @spec new() :: t()
    def new do
      time = System.monotonic_time(:microsecond)
      time = if(time < 0, do: -time, else: 0)
      %__MODULE__{base: time}
    end

    @spec get_time(t()) :: non_neg_integer()
    def get_time(%__MODULE__{base: base}) do
      # should be always positive thanks to this
      # TODO: storing such a huge values might be inefficient
      System.monotonic_time(:microsecond) + base
    end

    @spec to_ref(non_neg_integer()) :: non_neg_integer()
    def to_ref(timestamp), do: div(timestamp, 1000 * 64)

    @spec get_delta(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
    def get_delta(prev_ts, cur_ts) do
      delta = cur_ts - prev_ts
      # thanks to this delta is rounded to the closest value
      cond do
        delta < 0 -> delta - 125
        true -> delta + 125
      end
      |> div(250)
    end
  end

  import Bitwise

  alias ExRTCP.Packet.TransportFeedback.CC

  @uint8_range 0..255
  @int16_range -32_768..32_767

  @max_seq_num 0xFFFF
  @breakpoint 0x7FFF
  # packet window in microseconds
  @packet_window 500_000

  @type t() :: %__MODULE__{
          media_ssrc: non_neg_integer(),
          sender_ssrc: non_neg_integer(),
          base_seq_no: non_neg_integer() | nil,
          start_seq_no: non_neg_integer() | nil,
          end_seq_no: non_neg_integer() | nil,
          timestamps: %{non_neg_integer() => float()},
          fb_pkt_count: non_neg_integer()
        }

  # start, base - inclusive, end - exclusive
  # start, end - actual range where map values might be set
  # base - from where packets should be added to next feedback
  # if end_seq_no == start_seq_no, then no packets are available
  @enforce_keys [:media_ssrc, :sender_ssrc]
  defstruct @enforce_keys ++
              [
                timer: Timer.new(),
                base_seq_no: nil,
                start_seq_no: nil,
                end_seq_no: nil,
                timestamps: %{},
                fb_pkt_count: 0
              ]

  @spec record_packet(t(), non_neg_integer()) :: t()
  def record_packet(%{start_seq_no: nil, end_seq_no: nil} = recorder, seq_no) do
    # initial case, should only occur once
    timestamp = Timer.get_time(recorder.timer)

    %__MODULE__{
      recorder
      | base_seq_no: seq_no,
        start_seq_no: seq_no,
        end_seq_no: seq_no + 1,
        timestamps: %{seq_no => timestamp}
    }
  end

  def record_packet(recorder, raw_seq_no) do
    %__MODULE__{
      base_seq_no: base_seq_no,
      start_seq_no: start_seq_no,
      end_seq_no: end_seq_no,
      timestamps: timestamps
    } = recorder

    timestamp = Timer.get_time(recorder.timer)

    # internally, we don't wrap the sequence number around 2^16
    # so when receiving a new seq_num, we have to "unroll" it
    seq_no = unroll(raw_seq_no, end_seq_no)
    timestamps = Map.put_new(timestamps, seq_no, timestamp)
    base_seq_no = if seq_no < base_seq_no, do: seq_no, else: base_seq_no

    {start_seq_no, end_seq_no} =
      cond do
        seq_no < start_seq_no -> {seq_no, end_seq_no}
        seq_no >= end_seq_no -> {start_seq_no, seq_no + 1}
        true -> {start_seq_no, end_seq_no}
      end

    %__MODULE__{
      recorder
      | base_seq_no: base_seq_no,
        start_seq_no: start_seq_no,
        end_seq_no: end_seq_no,
        timestamps: timestamps
    }
    |> remove_old_packets(timestamp)
  end

  defp unroll(seq_no, end_seq_no) do
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
    %__MODULE__{
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
        recorder
        | base_seq_no: base_seq_no,
          start_seq_no: start_seq_no,
          end_seq_no: end_seq_no,
          timestamps: timestamps
      }
    end
  end

  @spec get_feedback(t()) :: {t(), [CC.t()]}
  def get_feedback(recorder, feedbacks \\ [])

  def get_feedback(%{base_seq_no: seq_no, end_seq_no: seq_no} = recorder, feedbacks),
    do: {recorder, Enum.reverse(feedbacks)}

  def get_feedback(recorder, feedbacks) do
    %__MODULE__{
      sender_ssrc: sender_ssrc,
      media_ssrc: media_ssrc,
      fb_pkt_count: fb_pkt_count,
      base_seq_no: base_seq_no,
      end_seq_no: end_seq_no,
      timestamps: timestamps
    } = recorder

    base_timestamp =
      base_seq_no..(end_seq_no - 1)
      |> Enum.find_value(&Map.get(timestamps, &1))

    # TODO: fix Timer.to_ref (we need to pass valid base_ts to add_packets)
    ref_timestamp = Timer.to_ref(base_timestamp)

    {chunks, deltas, new_base} =
      add_packets(timestamps, base_seq_no, end_seq_no, base_timestamp)

    feedback = %CC{
      media_ssrc: media_ssrc,
      sender_ssrc: sender_ssrc,
      fb_pkt_count: fb_pkt_count,
      base_sequence_number: roll(base_seq_no),
      packet_status_count: new_base - base_seq_no,
      reference_time: ref_timestamp,
      packet_chunks: Enum.reverse(chunks) |> Enum.map(&encode_chunk/1),
      recv_deltas: Enum.reverse(deltas)
    }

    recorder = %__MODULE__{
      recorder
      | fb_pkt_count: fb_pkt_count + 1,
        base_seq_no: new_base
    }

    # TODO: handle feedbacks with no packets?
    get_feedback(recorder, [feedback | feedbacks])
  end

  defp add_packets(timestamps, base_no, end_no, prev_ts, chunks \\ [], deltas \\ [])

  defp add_packets(_timestamps, end_no, end_no, _prev_ts, chunks, deltas) do
    {chunks, deltas, end_no}
  end

  defp add_packets(timestamps, base_no, end_no, prev_ts, chunks, deltas) do
    {delta, prev_ts} =
      case Map.fetch(timestamps, base_no) do
        {:ok, ts} -> {Timer.get_delta(prev_ts, ts), ts}
        :error -> {nil, prev_ts}
      end

    symbol =
      cond do
        is_nil(delta) -> :not_received
        delta in @uint8_range -> :small_delta
        delta in @int16_range -> :large_delta
        true -> nil
      end

    if is_nil(symbol) do
      {chunks, deltas, base_no}
    else
      chunks = add_to_chunk(symbol, chunks)
      deltas = [delta | deltas]
      add_packets(timestamps, base_no + 1, end_no, prev_ts, chunks, deltas)
    end
  end

  defp add_to_chunk(symbol, []), do: [new_chunk(symbol)]

  defp add_to_chunk(symbol, [last_chunk | rest_chunks]) do
    {symbols, large?, mixed?} = last_chunk

    if can_add?(symbols, large?, mixed?, symbol) do
      last_chunk = {
        [symbol | symbols],
        large? or symbol == :large_delta,
        mixed? or symbol != hd(symbols)
      }

      [last_chunk | rest_chunks]
    else
      new_chunk = new_chunk(symbol)
      [new_chunk, last_chunk | rest_chunks]
    end
  end

  defp new_chunk(symbol), do: {[symbol], symbol == :large_delta, false}

  defp can_add?(symbols, large?, mixed?, symbol) do
    length(symbols) < 7 or
      (length(symbols) < 14 and not large? and symbol != :large_delta) or
      (length(symbols) < 0x1FFF and not mixed? and symbol == hd(symbols))
  end

  defp encode_chunk({symbols, _large?, false}) do
    %CC.RunLength{run_length: length(symbols), status_symbol: hd(symbols)}
  end

  defp encode_chunk({symbols, _large?, _mixed?}) do
    # only the last packet's length might be different than 7 or 14
    # so I add padding of :not_received symbols
    # but the packet count in feedback header does not include the padding
    # so I assume it's fine and the padding is discarded by chrome?
    len = length(symbols)

    pad_len =
      cond do
        len <= 7 -> 7 - len
        len <= 14 -> 14 - len
      end

    symbols = List.duplicate(:not_received, pad_len) ++ symbols
    %CC.StatusVector{symbols: Enum.reverse(symbols)}
  end
end
