defmodule ExWebRTC.RTP.OpusDepayloader do
  @moduledoc """
  Decapsualtes Opus audio out of RTP packet.

  Based on [RFC 7587: RTP Payload Format for the Opus Speech and Audio Codec](https://datatracker.ietf.org/doc/html/rfc7587).
  """

  alias ExRTP.Packet

  @doc """
  Takes Opus packet out of an RTP packet.
  """
  @spec depayload(Packet.t()) :: binary()
  def depayload(%Packet{payload: payload}), do: payload
end
