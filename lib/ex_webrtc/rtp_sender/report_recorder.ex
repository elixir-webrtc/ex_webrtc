defmodule ExWebRTC.RTPSender.ReportRecorder do
  @moduledoc false

  import Bitwise

  alias ExRTCP.Packet.{ReceptionReport, SenderReport}
  alias ExWebRTC.Utils

  @breakpoint 0x7FFF
  # how many of our own Sender Reports we remember, so that a Receiver Report
  # referencing a slightly stale SR can still produce an RTT measurement.
  # Matches pion/interceptor's `maxLastSenderReports`.
  @max_sent_reports 5
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
          octet_count: non_neg_integer(),
          # {compact NTP timestamp of a sent SR, monotonic time of sending it}
          sent_reports: [{ExRTP.Packet.uint32(), integer()}]
        }

  defstruct clock_rate: nil,
            sender_ssrc: nil,
            last_rtp_timestamp: nil,
            last_seq_no: nil,
            last_timestamp: nil,
            packet_count: 0,
            octet_count: 0,
            sent_reports: []

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
  @spec get_report(t(), integer(), integer()) :: {:ok, SenderReport.t(), t()} | {:error, term()}
  def get_report(recorder, time \\ System.os_time(:native), mono_time \\ System.monotonic_time())

  def get_report(%{sender_ssrc: nil}, _time, _mono_time), do: {:error, :no_packets}

  def get_report(recorder, time, mono_time) do
    ntp_time = to_ntp(time)
    rtp_delta = delay_since(time, recorder.last_timestamp) * recorder.clock_rate

    report = %SenderReport{
      ssrc: recorder.sender_ssrc,
      packet_count: recorder.packet_count,
      octet_count: recorder.octet_count,
      ntp_timestamp: ntp_time,
      rtp_timestamp: round(recorder.last_rtp_timestamp + rtp_delta)
    }

    # Remember the compact (middle 32 bits) NTP time, which is what the remote
    # peer echoes back in the LSR field of its report blocks, together with the
    # monotonic moment we sent it (immune to wall-clock steps between the SR
    # and the corresponding RR). See RFC 3550, sec. 6.4.1.
    sent_reports =
      [{Utils.compact_ntp(ntp_time), mono_time} | recorder.sent_reports]
      |> Enum.take(@max_sent_reports)

    {:ok, report, %{recorder | sent_reports: sent_reports}}
  end

  @doc """
  Calculates the round-trip time, in seconds, based on a reception report block
  received from the remote peer.

  Implements `A - LSR - DLSR` from RFC 3550, sec. 6.4.1. Instead of doing the
  subtraction in compact NTP (which wraps every ~18 hours), we use the LSR field
  only to look up the report we sent, and measure the elapsed time directly.

  `mono_time` parameter accepts output of `System.monotonic_time()` as a value.
  """
  @spec get_rtt(t(), ReceptionReport.t(), integer()) ::
          {:ok, float()} | {:error, :no_last_sr | :no_matching_report}
  def get_rtt(recorder, report, mono_time \\ System.monotonic_time())

  # "If no SR packet has been received yet from SSRC_n, the DLSR field is set to zero."
  # (RFC 3550, sec. 6.4.1) - the same sentence defines LSR = 0 the same way.
  # A peer could in theory echo a valid LSR with a delay that rounded down to 0
  # (a sub-1/65536 s gap), but both pion and mediasoup treat delay == 0 as
  # "no SR received yet" and we follow them.
  def get_rtt(_recorder, %ReceptionReport{last_sr: 0}, _mono_time), do: {:error, :no_last_sr}
  def get_rtt(_recorder, %ReceptionReport{delay: 0}, _mono_time), do: {:error, :no_last_sr}

  def get_rtt(recorder, %ReceptionReport{last_sr: lsr, delay: dlsr}, mono_time) do
    case List.keyfind(recorder.sent_reports, lsr, 0) do
      {^lsr, sent_mono_time} ->
        # DLSR is expressed in units of 1/65536 seconds
        rtt = delay_since(mono_time, sent_mono_time) - dlsr / 65_536

        # A remote peer with a skewed clock, or a report that raced our own SR,
        # can claim a delay longer than the time that actually elapsed.
        {:ok, max(rtt, 0.0)}

      nil ->
        {:error, :no_matching_report}
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
