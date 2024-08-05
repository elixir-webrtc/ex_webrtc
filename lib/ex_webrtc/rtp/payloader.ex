defmodule ExWebRTC.RTP.Payloader do
  @moduledoc """
  Behaviour for ExWebRTC Payloaders.
  """

  @type payloader :: struct()

  @doc """
  Creates a new payloader struct.

  Refer to the modules implementing the behaviour for available options.
  """
  @callback new(options :: any()) :: payloader()

  @doc """
  Packs a frame into one or more RTP packets.

  Returns the packets together with the updated payloader struct.
  """
  @callback payload(payloader(), frame :: binary()) :: {[ExRTP.Packet.t()], payloader()}
end
