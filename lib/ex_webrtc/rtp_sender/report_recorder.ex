defmodule ExWebRTC.RTPSender.ReportRecorder do
  @moduledoc false

  import Bitwise

  alias ExRTCP.Packet.SenderReport

  @breakpoint 0x7FFF
  # NTP epoch is 1/1/1900 vs UNIX epoch is 1/1/1970
  # so there's offset of 70 years (inc. 17 leap years) in seconds
  @ntp_offset (70 * 365 + 17) * 86_400
  @micro_in_sec 1_000_000

  @type t() :: %__MODULE__{
          sender_ssrc: non_neg_integer() | nil,
          clock_rate: non_neg_integer() | nil,
          last_rtp_timestamp: ExRTP.Packet.uint32() | nil,
          last_seq_no: ExRTP.Packet.uint16() | nil,
          last_timestamp: integer() | nil,
          packet_count: non_neg_integer(),
          octet_count: non_neg_integer()
        }

  defstruct clock_rate: nil,
            sender_ssrc: nil,
            last_rtp_timestamp: nil,
            last_seq_no: nil,
            last_timestamp: nil,
            packet_count: 0,
            octet_count: 0

  @doc """
  Records outgoing RTP Packet.
  `time` parameter accepts output of `System.os_time(:native)` as a value (UNIX timestamp in :native units).
  """
  @spec record_packet(t(), ExRTP.Packet.t(), integer()) :: t()
  def record_packet(%{last_timestamp: nil} = recorder, packet, time) do
    %__MODULE__{
      recorder
      | sender_ssrc: packet.ssrc,
        last_rtp_timestamp: packet.timestamp,
        last_seq_no: packet.sequence_number,
        last_timestamp: time,
        packet_count: 1,
        octet_count: byte_size(packet.payload)
    }
  end

  def record_packet(recorder, packet, time) do
    %__MODULE__{
      last_seq_no: last_seq_no,
      packet_count: packet_count,
      octet_count: octet_count
    } = recorder

    # a packet is in order when it is from the next cycle, or from current cycle with delta > 0
    delta = packet.sequence_number - last_seq_no
    in_order? = delta < -@breakpoint or (delta > 0 and delta < @breakpoint)

    recorder =
      if in_order? do
        %__MODULE__{
          recorder
          | last_seq_no: packet.sequence_number,
            last_rtp_timestamp: packet.timestamp,
            last_timestamp: time
        }
      else
        recorder
      end

    %__MODULE__{
      recorder
      | packet_count: packet_count + 1,
        octet_count: octet_count + byte_size(packet.payload)
    }
  end

  @doc """
  Creates an RTCP Sender Report.
  `time` parameter accepts output of `System.os_time(:native)` as a value (UNIX timestamp in :native units).

  This function can be called only if at least one packet has been recorded,
  otherwise it will raise.
  """
  @spec get_report(t(), integer()) :: SenderReport.t()
  def get_report(%{last_timestamp: nil}, _time), do: raise("No packet has been recorded yet")
  def get_report(%{clock_rate: nil}, _time), do: raise("Clock rate was not set")

  def get_report(recorder, time) do
    ntp_time = to_ntp(time)
    rtp_delta = delay_since(time, recorder.last_timestamp) * recorder.clock_rate

    %SenderReport{
      ssrc: recorder.sender_ssrc,
      packet_count: recorder.packet_count,
      octet_count: recorder.octet_count,
      ntp_timestamp: ntp_time,
      rtp_timestamp: round(recorder.last_rtp_timestamp + rtp_delta)
    }
  end

  defp to_ntp(time) do
    seconds = System.convert_time_unit(time, :native, :second)
    micros = System.convert_time_unit(time, :native, :microsecond) - seconds * @micro_in_sec

    frac = div(micros <<< 32, @micro_in_sec)

    (seconds + @ntp_offset) <<< 32 ||| frac
  end

  defp delay_since(cur_ts, last_ts) do
    native_in_sec = System.convert_time_unit(1, :second, :native)
    (cur_ts - last_ts) / native_in_sec
  end
end
