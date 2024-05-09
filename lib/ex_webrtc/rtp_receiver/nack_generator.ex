defmodule ExWebRTC.RTPReceiver.NACKGenerator do
  @moduledoc false
  # for now, it mimics the Pion implementation, but there's some issues and remarks
  # 1) NACKs are send at constant interval
  # 2) no timing rules (like rtt) are taken into account
  # 3) NACKs will be sent until max_nacks NACKs has been sent or sn is older than @max_sn

  alias ExRTCP.Packet.TransportFeedback.NACK

  @max_nack 3
  @max_sn 0xFFFF
  @breakpoint 0x7FFF

  @type t() :: %__MODULE__{
          media_ssrc: non_neg_integer() | nil,
          sender_ssrc: non_neg_integer(),
          lost_packets: %{non_neg_integer() => non_neg_integer()},
          last_sn: non_neg_integer() | nil,
          max_nack: non_neg_integer()
        }

  defstruct sender_ssrc: 1,
            media_ssrc: nil,
            lost_packets: %{},
            last_sn: nil,
            max_nack: @max_nack

  @spec record_packet(t(), ExRTP.Packet.t()) :: t()
  def record_packet(generator, packet)

  def record_packet(%{last_sn: nil} = generator, packet) do
    %__MODULE__{generator | media_ssrc: packet.ssrc, last_sn: packet.sequence_number}
  end

  def record_packet(generator, packet) do
    %__MODULE__{
      lost_packets: lost_packets,
      last_sn: last_sn,
      max_nack: max_nack
    } = generator

    delta = packet.sequence_number - last_sn
    in_order? = delta < -@breakpoint or (delta > 0 and delta < @breakpoint)

    {lost_packets, last_sn} =
      if in_order? do
        lost_packets = set_missing(lost_packets, max_nack, last_sn, packet.sequence_number)
        {lost_packets, packet.sequence_number}
      else
        lost_packets = Map.delete(lost_packets, packet.sequence_number)
        {lost_packets, last_sn}
      end

    %__MODULE__{
      generator
      | lost_packets: lost_packets,
        last_sn: last_sn
    }
  end

  defp set_missing(lost_packets, max_nack, from, to) when from <= to do
    do_set_missing(lost_packets, max_nack, from + 1, to - 1)
  end

  defp set_missing(lost_packets, max_nack, from, to) do
    lost_packets
    |> do_set_missing(max_nack, from + 1, @max_sn)
    |> do_set_missing(max_nack, 0, to - 1)
  end

  defp do_set_missing(lost_packets, max_nack, from, to) do
    Enum.reduce(from..to//1, lost_packets, fn sn, lost_packets ->
      Map.put(lost_packets, sn, max_nack)
    end)
  end

  @spec get_feedback(t()) :: {NACK.t() | nil, t()}
  def get_feedback(generator) do
    %__MODULE__{
      media_ssrc: media_ssrc,
      sender_ssrc: sender_ssrc,
      lost_packets: lost_packets
    } = generator

    missing_sn = Map.keys(lost_packets)

    lost_packets =
      Enum.reduce(missing_sn, lost_packets, fn sn, lost_packets ->
        {nacks, lost_packets} = Map.pop!(lost_packets, sn)

        if nacks > 1 do
          Map.put(lost_packets, sn, nacks - 1)
        else
          lost_packets
        end
      end)

    if length(missing_sn) != 0 do
      feedback = NACK.from_sequence_numbers(sender_ssrc, media_ssrc, missing_sn)
      generator = %__MODULE__{generator | lost_packets: lost_packets}

      {feedback, generator}
    else
      {nil, generator}
    end
  end
end
