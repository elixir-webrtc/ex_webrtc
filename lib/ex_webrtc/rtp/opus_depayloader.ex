defmodule ExWebRTC.RTP.OpusDepayloader do
  @moduledoc """
  Decapsualtes Opus audio out of RTP packet.
  """

  alias ExRTP.Packet

  @doc """
  Takes Opus packet out of an RTP packet.
  """
  @spec depayload(Packet.t()) :: binary()
  def depayload(%Packet{payload: payload}), do: payload
end
