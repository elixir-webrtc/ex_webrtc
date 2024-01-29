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
      System.monotonic_time(:microsecond) + base
    end

    @spec to_ref(non_neg_integer()) :: non_neg_integer()
    def to_ref(timestamp), do: div(timestamp, 1000 * 64)

    @spec get_delta(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
    def get_delta(ref, timestamp) do
      # ref as returned from `to_ref/1`
      # timestamp as returned by `get_time/1`
      ref_timestamp = ref * 64 * 1000
      delta = timestamp - ref_timestamp
      div(delta, 250)
    end
  end

  import Bitwise

  alias ExRTCP.Packet.TransportFeedback.CC

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
  # if end_seq_no >= start_seq_no, then no packets are available
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
    # initial case
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
    timestamp = Timer.get_time(recorder.timer)

    %__MODULE__{
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
      recorder
      | base_seq_no: base_seq_no,
        start_seq_no: start_seq_no,
        end_seq_no: end_seq_no,
        timestamps: timestamps
    }
    |> remove_old_packets(timestamp)
  end

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
    {feedback, recorder} = create_feedback(recorder)
    get_feedback(recorder, [feedback | feedbacks])
  end

  def create_feedback(recorder) do
    %__MODULE__{
      sender_ssrc: sender_ssrc,
      media_ssrc: media_ssrc,
      fb_pkt_count: fb_pkt_count,
      base_seq_no: base_seq_no,
      end_seq_no: end_seq_no,
      timestamps: timestamps
    } = recorder

    reference_time =
      base_seq_no..(end_seq_no - 1)
      |> Enum.find_value(&Map.get(timestamps, &1))
      |> Timer.to_ref()

    feedback = %CC{
      sender_ssrc: sender_ssrc,
      media_ssrc: media_ssrc,
      fb_pkt_count: fb_pkt_count,
      packet_status_count: 0,
      base_sequence_number: base_seq_no,
      reference_time: reference_time
    }

    # TODO: add packets
    new_base = :siema

    recorder = %__MODULE__{recorder | fb_pkt_count: fb_pkt_count + 1, base_seq_no: new_base}
    {feedback, recorder}
  end
end
