defmodule ExWEbRTC.RTPSender.ReportRecorder do
  @moduledoc false

  alias ExRTCP.Packet.SenderReport

  @breakpoint 0x7FFF

  @type t() :: %__MODULE__{
          sender_ssrc: non_neg_integer(),
          clock_rate: non_neg_integer(),
          last_rtp_timestamp: ExRTP.Packet.uint32(),
          last_seq_no: ExRTP.Packet.uint16(),
          last_timestamp: integer(),
          packet_count: non_neg_integer(),
          octet_count: non_neg_integer()
        }

  @enforce_keys [:sender_ssrc, :clock_rate]
  defstruct [
              last_rtp_timestamp: nil,
              last_seq_no: nil,
              last_timestamp: nil,
              packet_count: 0,
              octet_count: 0
            ] ++ @enforce_keys

  @doc """
  Records outgoing RTP Packet.
  `time` parameter accepts output of `System.os_time(:native)` as a value.
  """
  @spec record_packet(t(), ExRTP.Packet.t(), integer()) :: t()
  def record_packet(%{last_timestamp: nil} = recorder, packet, time) do
    %__MODULE__{
      recorder
      | last_rtp_timestamp: packet.timestamp,
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
  `time` parameter accepts output of `System.os_time(:native)` as a value.
  """
  @spec get_report(t(), integer()) :: {SenderReport.t(), t()}
  def get_report(_recorder, _time) do
    # TODO
    raise("not implemented")
  end
end
