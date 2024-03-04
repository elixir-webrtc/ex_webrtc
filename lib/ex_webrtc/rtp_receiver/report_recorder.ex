defmodule ExWebRTC.RTPReceiver.ReportRecorder do
  @moduledoc false
  # based on https://datatracker.ietf.org/doc/html/rfc3550#section-6.4.1

  import Bitwise

  alias ExRTCP.Packet.{ReceiverReport, ReceptionReport}

  @max_u32 0xFFFFFFFF
  @max_u24 0xFFFFFF
  @max_seq_no 0xFFFF
  @breakpoint 0x7FFF

  @type t() :: %__MODULE__{
          media_ssrc: non_neg_integer() | nil,
          sender_ssrc: non_neg_integer(),
          clock_rate: non_neg_integer() | nil,
          lost_packets: MapSet.t(),
          last_seq_no: {non_neg_integer(), ExRTP.Packet.uint16()} | nil,
          last_report_seq_no: {non_neg_integer(), ExRTP.Packet.uint16()} | nil,
          last_rtp_timestamp: ExRTP.Packet.uint32() | nil,
          last_timestamp: integer() | nil,
          last_sr_ntp_timestamp: ExRTP.Packet.uint32(),
          last_sr_timestamp: integer() | nil,
          jitter: float(),
          total_lost: non_neg_integer()
        }

  defstruct sender_ssrc: 1,
            clock_rate: nil,
            media_ssrc: nil,
            lost_packets: MapSet.new(),
            last_seq_no: nil,
            last_report_seq_no: nil,
            last_rtp_timestamp: nil,
            last_timestamp: nil,
            last_sr_ntp_timestamp: 0,
            last_sr_timestamp: nil,
            jitter: 0.0,
            total_lost: 0

  @doc """
  Records incoming RTP Packet.
  `time` parameter accepts output of `System.monotonic_time(:native)` as a value.
  """
  @spec record_packet(t(), ExRTP.Packet.t(), integer()) :: t()
  def record_packet(%{clock_rate: nil}, _packet, _time), do: raise("Clock rate was not set")

  def record_packet(%{last_seq_no: nil} = recorder, packet, time) do
    # seq_no == {cycle_no, seq_no as in RTP packet}
    %__MODULE__{
      recorder
      | media_ssrc: packet.ssrc,
        last_seq_no: {0, packet.sequence_number},
        last_report_seq_no: {0, packet.sequence_number - 1},
        last_rtp_timestamp: packet.timestamp,
        last_timestamp: time
    }
  end

  def record_packet(recorder, packet, time) do
    recorder
    |> record_seq_no(packet.sequence_number)
    |> record_jitter(packet.timestamp, time)
  end

  @doc """
  Records incoming RTCP Sender Report.
  `time` parameter accepts output of `System.monotonic_time(:native)` as a value.
  """
  @spec record_report(t(), ExRTCP.Packet.SenderReport.t(), integer()) :: t()
  def record_report(recorder, sender_report, time) do
    # we take the middle 32 bits of the NTP timestamp
    ntp_ts = sender_report.ntp_timestamp >>> 16 &&& @max_u32

    %__MODULE__{recorder | last_sr_ntp_timestamp: ntp_ts, last_sr_timestamp: time}
  end

  @doc """
  Creates an RTCP Receiver Report.
  `time` parameter accepts output of `System.monotonic_time(:native)` as a value.
  """
  @spec get_report(t(), integer()) :: {:ok, ReceiverReport.t(), t()} | {:error, term()}
  def get_report(%{media_ssrc: nil}, _time), do: {:error, :no_packets}

  def(get_report(recorder, time)) do
    received =
      recorder.last_seq_no
      |> seq_no_diff(recorder.last_report_seq_no)
      |> min(@max_u24)

    lost =
      recorder.lost_packets
      |> MapSet.size()
      |> min(@max_u24)

    total_lost = min(recorder.total_lost + lost, @max_u24)

    {cycle, seq_no} = recorder.last_seq_no

    report = %ReceiverReport{
      ssrc: recorder.sender_ssrc,
      reports: [
        %ReceptionReport{
          ssrc: recorder.media_ssrc,
          delay: round(delay_since(time, recorder.last_sr_timestamp) * 65_536),
          last_sr: recorder.last_sr_ntp_timestamp,
          last_sequence_number: (cycle <<< 16 &&& @max_u32) ||| seq_no,
          fraction_lost: round(lost * 256 / received),
          total_lost: total_lost,
          jitter: round(recorder.jitter)
        }
      ]
    }

    recorder = %__MODULE__{
      recorder
      | lost_packets: MapSet.new(),
        last_report_seq_no: recorder.last_seq_no,
        total_lost: total_lost
    }

    {:ok, report, recorder}
  end

  defp record_seq_no(recorder, rtp_seq_no) do
    %__MODULE__{
      lost_packets: lost_packets,
      last_seq_no: {last_cycle, last_rtp_seq_no} = last_seq_no
    } = recorder

    delta = rtp_seq_no - last_rtp_seq_no

    cycle =
      cond do
        delta in -@breakpoint..@breakpoint -> last_cycle
        delta < -@breakpoint -> last_cycle + 1
        delta > @breakpoint -> last_cycle - 1
      end

    # NOTICE: cycle might be -1 in very specific cases (e.g. the very first packet is 2^16 - 1,
    # second packet is 0, but we received the second packet first).
    # We just ignore these packets. Similarly, we ignore packets that arrived late
    # (counted as lost in previous report) instead of changing the last_report_seq_no
    # to lower value to include them.
    seq_no = {cycle, rtp_seq_no}

    {last_seq_no, lost_packets} =
      if seq_no <= last_seq_no do
        lost_packets = MapSet.delete(lost_packets, seq_no)
        {last_seq_no, lost_packets}
      else
        lost_packets = set_lost_packets(next_seq_no(last_seq_no), seq_no, lost_packets)
        {seq_no, lost_packets}
      end

    %__MODULE__{recorder | last_seq_no: last_seq_no, lost_packets: lost_packets}
  end

  defp set_lost_packets(start_seq_no, end_seq_no, lost_packets)
       when start_seq_no == end_seq_no,
       do: lost_packets

  defp set_lost_packets(start_seq_no, end_seq_no, lost_packets) do
    lost_packets = MapSet.put(lost_packets, start_seq_no)
    set_lost_packets(next_seq_no(start_seq_no), end_seq_no, lost_packets)
  end

  defp next_seq_no({cycle, @max_seq_no}), do: {cycle + 1, 0}
  defp next_seq_no({cycle, seq_no}), do: {cycle, seq_no + 1}

  defp record_jitter(recorder, rtp_ts, cur_ts) do
    %__MODULE__{
      last_rtp_timestamp: last_rtp_ts,
      last_timestamp: last_ts,
      jitter: jitter,
      clock_rate: clock_rate
    } = recorder

    wlc_diff = native_to_sec(cur_ts - last_ts)
    rtp_diff = rtp_ts - last_rtp_ts
    diff = wlc_diff * clock_rate - rtp_diff
    jitter = jitter + (abs(diff) - jitter) / 16

    %__MODULE__{
      recorder
      | last_rtp_timestamp: rtp_ts,
        last_timestamp: cur_ts,
        jitter: jitter
    }
  end

  defp native_to_sec(time) do
    native_in_sec = System.convert_time_unit(1, :second, :native)
    time / native_in_sec
  end

  defp seq_no_diff({cycle_a, seq_no_a}, {cycle_b, seq_no_b}) do
    cycle_diff = cycle_a - cycle_b
    seq_no_diff = seq_no_a - seq_no_b
    cycle_diff * (@max_seq_no + 1) + seq_no_diff
  end

  defp delay_since(_cur_ts, nil), do: 0
  defp delay_since(cur_ts, last_ts), do: native_to_sec(cur_ts - last_ts)
end
