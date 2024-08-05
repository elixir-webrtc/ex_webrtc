defmodule ExWebRTC.RTP.Opus.Payloader do
  @moduledoc """
  Encapsulates Opus audio packet into an RTP packet.

  Based on [RFC 7587: RTP Payload Format for the Opus Speech and Audio Codec](https://datatracker.ietf.org/doc/html/rfc7587).
  """

  @behaviour ExWebRTC.RTP.Payloader

  @opaque t :: %__MODULE__{}

  @enforce_keys []
  defstruct @enforce_keys

  @doc """
  Creates a new Opus payloader struct.

  Does not take any options/parameters.
  """
  @impl true
  @spec new(any()) :: t()
  def new(_unused \\ nil) do
    %__MODULE__{}
  end

  @doc """
  Packs Opus packet into an RTP packet.

  Fields from RTP header like ssrc, timestamp etc. are set to 0.
  Always returns a single RTP packet.
  """
  @impl true
  @spec payload(t(), binary()) :: {[ExRTP.Packet.t()], t()}
  def payload(%__MODULE__{} = payloader, packet) when packet != <<>> do
    {[ExRTP.Packet.new(packet)], payloader}
  end
end
