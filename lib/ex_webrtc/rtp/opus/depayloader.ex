defmodule ExWebRTC.RTP.Opus.Depayloader do
  @moduledoc """
  Decapsualtes Opus audio out of RTP packet.

  Based on [RFC 7587: RTP Payload Format for the Opus Speech and Audio Codec](https://datatracker.ietf.org/doc/html/rfc7587).
  """

  alias ExRTP.Packet

  @behaviour ExWebRTC.RTP.Depayloader

  @opaque t :: %__MODULE__{}

  @enforce_keys []
  defstruct @enforce_keys

  @doc """
  Creates a new Opus depayloader struct.

  Does not take any options/parameters.
  """
  @impl true
  @spec new(any()) :: t()
  def new(_unused \\ nil) do
    %__MODULE__{}
  end

  @doc """
  Takes Opus packet out of an RTP packet.

  Always returns a binary as the first element.
  """
  @impl true
  @spec depayload(t(), Packet.t()) :: {binary(), t()}
  def depayload(%__MODULE__{} = depayloader, %Packet{payload: payload}),
    do: {payload, depayloader}
end
