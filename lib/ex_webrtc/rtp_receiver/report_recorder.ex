defmodule ExWebRTC.RTPReceiver.ReportRecorder do
  @moduledoc false

  import Bitwise

  @max_u32 0xFFFFFFFF
  @max_seq_no 0xFFFF
  @breakpoint 0x7FFF

  @type t() :: %__MODULE__{
          lost_packets: MapSet.t(),
          last_seq_no: {non_neg_integer(), ExRTP.Packet.uint16()},
          last_report_seq_no: {non_neg_integer(), ExRTP.Packet.uint16()},
          last_rtp_timestamp: ExRTP.Packet.uint32(),
          last_timestamp: integer(),
          last_sr_ntp_timestamp: ExRTP.Packet.uint32(),
          last_sr_timestamp: integer(),
          jitter: float()
        }

  @enforce_keys [:sender_ssrc, :ssrc, :clock_rate]
  defstruct [
              lost_packets: MapSet.new(),
              last_seq_no: nil,
              last_report_seq_no: nil,
              last_rtp_timestamp: nil,
              last_timestamp: nil,
              last_sr_ntp_timestamp: 0,
              last_sr_timestamp: 0,
              jitter: 0
            ] ++ @enforce_keys

  # time as returned by System.monotonic_time/0, in :native unit
  @spec record_packet(t(), ExRTP.Packet.t(), integer()) :: t()
  def record_packet(%{last_seq_no: nil} = recorder, packet, time) do
    # seq_no == {cycle_no, seq_no as in RTP packet}
    %__MODULE__{
      recorder
      | last_seq_no: {0, packet.sequence_number},
        last_report_seq_no: {0, packet.sequence_number},
        last_rtp_timestamp: packet.timestamp,
        last_timestamp: time
    }
  end

  def record_packet(recorder, packet, time) do
    recorder
    |> record_seq_no(packet.sequence_number)
    |> record_jitter(packet.timestamp, time)
  end

  @spec record_report(t(), ExRTCP.Packet.SenderReport.t(), integer()) :: t()
  def record_report(recorder, sender_report, time) do
    # we take the middle 32 bits of the NTP timestamp
    ntp_ts = sender_report.ntp_timestamp >>> 16 &&& @max_u32

    %__MODULE__{recorder | last_sr_ntp_timestamp: ntp_ts, last_sr_timestamp: time}
  end

  @spec get_report(t()) :: {ExRTCP.Packet.ReceiverReport.t(), t()}
  def get_report(recorder) do
    # TODO: implement this
    report = %ExRTCP.Packet.ReceiverReport{ssrc: recorder.sender_ssrc}
    {report, recorder}
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

    seq_no = {cycle, rtp_seq_no}
    {last_seq_no, lost_packets}

    if seq_no <= last_seq_no do
      lost_packets = MapSet.delete(lost_packets, last_seq_no)
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
  defp next_seq_no({cycle, seq_no}), do: {cycle, seq_no}

  defp record_jitter(recorder, rtp_ts, cur_ts) do
    %__MODULE__{
      last_rtp_timestamp: last_rtp_ts,
      last_timestamp: last_ts,
      jitter: jitter,
      clock_rate: clock_rate
    } = recorder

    # see https://tools.ietf.org/html/rfc3550#page-39
    wlc_diff = native_to_sec(cur_ts - last_ts)
    rtp_diff = rtp_ts - last_rtp_ts
    diff = wlc_diff * clock_rate - rtp_diff
    jitter = jitter + abs(diff) - jitter / 16

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
end
