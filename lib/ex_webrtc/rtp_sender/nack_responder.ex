defmodule ExWebRTC.RTPSender.NACKResponder do
  @moduledoc false

  import Bitwise

  alias ExRTP.Packet
  alias ExRTCP.Packet.TransportFeedback.NACK

  @default_size 1024

  @type t() :: %__MODULE__{
          packets: %{non_neg_integer() => Packet.t()},
          seq_no: non_neg_integer(),
          size: pos_integer()
        }

  defstruct packets: %{},
            seq_no: 0,
            size: @default_size

  @doc """
  Creates a new responder that keeps up to `size` most recently sent packets.

  The first RTX sequence number is chosen at random.
  """
  @spec new(pos_integer()) :: t()
  def new(size \\ @default_size) do
    %__MODULE__{seq_no: Enum.random(0..0xFFFF), size: size}
  end

  @spec record_packet(t(), Packet.t()) :: t()
  def record_packet(%__MODULE__{} = responder, packet) do
    key = rem(packet.sequence_number, responder.size)
    packets = Map.put(responder.packets, key, packet)

    %{responder | packets: packets}
  end

  @spec get_rtx(t(), NACK.t()) :: {[ExRTP.Packet.t()], t()}
  def get_rtx(%__MODULE__{} = responder, nack) do
    seq_nos = NACK.to_sequence_numbers(nack)

    {packets, seq_no} =
      seq_nos
      |> Enum.map(fn seq_no ->
        {seq_no, Map.get(responder.packets, rem(seq_no, responder.size))}
      end)
      |> Enum.filter(fn {seq_no, packet} ->
        packet != nil and packet.sequence_number == seq_no
      end)
      # ssrc will be assigned by the sender
      |> Enum.map_reduce(responder.seq_no, fn {seq_no, %Packet{} = packet}, rtx_seq_no ->
        rtx_packet = %{
          packet
          | sequence_number: rtx_seq_no,
            payload: <<seq_no::16, packet.payload::binary>>
        }

        {rtx_packet, rtx_seq_no + 1 &&& 0xFFFF}
      end)

    responder = %__MODULE__{responder | seq_no: seq_no}
    {packets, responder}
  end
end
