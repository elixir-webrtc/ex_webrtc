defmodule ExWebRTC.RTP.Payloader.Behaviour do
  @moduledoc false

  @type payloader :: struct()

  @doc """
  Creates a new payloader struct.
  """
  @callback new(max_payload_size :: integer()) :: payloader()

  @doc """
  Packs a frame into one or more RTP packets.

  Returns the packets together with the updated payloader struct.
  """
  @callback payload(payloader(), frame :: binary()) :: {[ExRTP.Packet.t()], payloader()}
end
