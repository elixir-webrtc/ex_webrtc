defmodule ExWebRTC.RTP.PacketFactory do
  @moduledoc false

  alias ExRTP.Packet

  @timestamp_increment 30_000
  @base_seq_number 50

  @spec base_seq_number() :: Packet.uint16()
  def base_seq_number(), do: @base_seq_number

  @spec sample_packet(Packet.uint16()) :: Packet.t()
  def sample_packet(seq_num) do
    seq_num_offset = seq_num - @base_seq_number

    Packet.new(
      <<0, 255>>,
      payload_type: 127,
      ssrc: 0xDEADCAFE,
      timestamp: seq_num_offset * @timestamp_increment,
      sequence_number: seq_num
    )
  end
end
