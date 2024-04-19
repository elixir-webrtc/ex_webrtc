defmodule ExWebRTC.RTPSender.NACKResponder do
  @moduledoc nil

  alias ExRTP.Packet
  alias ExRTCP.Packet.TransportFeedback.NACK

  @max_packets 200

  @type t() :: %__MODULE__{
          packets: %{non_neg_integer() => Packet.t()},
          seq_no: non_neg_integer()
        }

  defstruct packets: %{},
            seq_no: Enum.random(0..0xFFFF)

  @doc """
  Records send RTP packets.
  """
  @spec record_packet(t(), Packet.t()) :: t()
  def record_packet(responder, packet) do
    key = rem(packet.sequence_number, @max_packets)
    packets = Map.put(responder.packets, key, packet)

    %__MODULE__{responder | packets: packets}
  end

  @doc """
  Returns RTX RTP packets to be retransmited based on received NACK feedback.
  """
  @spec get_rtx(t(), NACK.t()) :: {[ExRTP.Packet.t()], t()}
  def get_rtx(responder, nack) do
    seq_nos = NACK.to_sequence_numbers(nack)

    {packets, seq_no} =
      seq_nos
      |> Enum.map(fn seq_no -> {seq_no, Map.get(responder.packets, rem(seq_no, @max_packets))} end)
      |> Enum.filter(fn {seq_no, packet} -> packet != nil and packet.sequence_number == seq_no end)
      # ssrc will be assigned by the sender
      |> Enum.map_reduce(responder.seq_no, fn {seq_no, packet}, rtx_seq_no ->
        rtx_packet = %Packet{
          packet
          | sequence_number: rtx_seq_no,
            payload: <<seq_no::16, packet.payload::binary>>
        }

        {rtx_packet, rtx_seq_no + 1}
      end)

    responder = %__MODULE__{responder | seq_no: seq_no}
    {packets, responder}
  end
end
