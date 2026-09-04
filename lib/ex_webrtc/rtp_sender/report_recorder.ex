defmodule ExWebRTC.RTPSender.ReportRecorder do
  @moduledoc false

  import Bitwise

  alias ExRTCP.Packet.{ReceptionReport, SenderReport}

  @breakpoint 0x7FFF
  @max_u32 0xFFFFFFFF
  # `System.os_time/1` may jump backwards, and the masked subtraction in get_rtt/2
  # cannot express a negative result: a step back of even 15 us aliases to nearly
  # the full 2^32 range (~18 h). Reject anything beyond this bound rather than
  # feed an absurd measurement into the stats. Compact NTP units of 1/65536 s.
  @max_elapsed 30 * 65_536
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

  @spec init(t(), non_neg_integer(), non_neg_integer()) :: t()
  def init(%{clock_rate: nil, sender_ssrc: nil}, clock_rate, sender_ssrc) do
    %__MODULE__{clock_rate: clock_rate, sender_ssrc: sender_ssrc}
  end

  def init(_recorder, _clock_rate, _sender_ssrc),
    do: raise("Tried to re-initialize ReportRecorder")

  @doc """
  Records incoming RTP packet.

  `time` parameter accepts output of `System.os_time(:native)` as a value (UNIX timestamp in :native units).
  """
  @spec record_packet(t(), ExRTP.Packet.t(), integer()) :: t()
  def record_packet(recorder, packet, time \\ System.os_time(:native))

  def record_packet(%{clock_rate: nil}, _packet, _time), do: raise("Clock rate was not set")

  def record_packet(%__MODULE__{last_seq_no: nil} = recorder, packet, time) do
    %{
      recorder
      | last_rtp_timestamp: packet.timestamp,
        last_seq_no: packet.sequence_number,
        last_timestamp: time,
        packet_count: 1,
        octet_count: byte_size(packet.payload)
    }
  end

  def record_packet(
        %__MODULE__{
          last_seq_no: last_seq_no,
          packet_count: packet_count,
          octet_count: octet_count
        } = recorder,
        packet,
        time
      ) do
    # a packet is in order when it is from the next cycle, or from current cycle with delta > 0
    delta = packet.sequence_number - last_seq_no
    in_order? = delta < -@breakpoint or (delta > 0 and delta < @breakpoint)

    recorder =
      if in_order? do
        %{
          recorder
          | last_seq_no: packet.sequence_number,
            last_rtp_timestamp: packet.timestamp,
            last_timestamp: time
        }
      else
        recorder
      end

    %{
      recorder
      | packet_count: packet_count + 1,
        octet_count: octet_count + byte_size(packet.payload)
    }
  end

  @doc """
  Generates a RTCP Sender Report.

  `time` parameter accepts output of `System.os_time(:native)` as a value (UNIX timestamp in :native units).
  This function can be called only if at least one packet has been recorded,
  otherwise it will raise.
  """
  @spec get_report(t(), integer()) :: {:ok, SenderReport.t(), t()} | {:error, term()}
  def get_report(recorder, time \\ System.os_time(:native))

  def get_report(%{sender_ssrc: nil}, _time), do: {:error, :no_packets}

  def get_report(recorder, time) do
    ntp_time = to_ntp(time)
    rtp_delta = delay_since(time, recorder.last_timestamp) * recorder.clock_rate

    report = %SenderReport{
      ssrc: recorder.sender_ssrc,
      packet_count: recorder.packet_count,
      octet_count: recorder.octet_count,
      ntp_timestamp: ntp_time,
      rtp_timestamp: round(recorder.last_rtp_timestamp + rtp_delta)
    }

    {:ok, report, recorder}
  end

  @spec get_rtt(ReceptionReport.t(), integer()) ::
          {:ok, float()} | {:error, :no_last_sr | :invalid_last_sr}
  def get_rtt(report, time \\ System.os_time(:native))
  def get_rtt(%ReceptionReport{last_sr: 0}, _time), do: {:error, :no_last_sr}
  def get_rtt(%ReceptionReport{delay: 0}, _time), do: {:error, :no_last_sr}

  def get_rtt(%ReceptionReport{last_sr: lsr, delay: dlsr}, time) do
    now = to_ntp(time) >>> 16 &&& @max_u32
    elapsed = now - lsr &&& @max_u32

    if elapsed > @max_elapsed do
      {:error, :invalid_last_sr}
    else
      # A remote peer with a skewed clock, or a report that raced our own SR,
      # can claim a delay longer than the time that actually elapsed.
      {:ok, max(elapsed - dlsr, 0) / 65_536}
    end
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
