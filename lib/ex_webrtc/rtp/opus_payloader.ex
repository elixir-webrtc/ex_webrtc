defmodule ExWebRTC.RTP.OpusPayloader do
  @moduledoc """
  Encapsulates Opus audio packet into an RTP packet.
  """

  @doc """
  Packs Opus packet into an RTP packets.

  Fields from RTP header like ssrc, timestamp etc. are set to 0.
  """
  @spec payload(binary()) :: ExRTP.Packet.t()
  def payload(packet) when packet != <<>> do
    ExRTP.Packet.new(packet, 0, 0, 0, 0)
  end
end
