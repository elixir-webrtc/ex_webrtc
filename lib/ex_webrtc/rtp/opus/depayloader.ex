defmodule ExWebRTC.RTP.Depayloader.Opus do
  @moduledoc false
  # Decapsualtes Opus audio out of RTP packet.
  #
  # Based on [RFC 7587: RTP Payload Format for the Opus Speech and Audio Codec](https://datatracker.ietf.org/doc/html/rfc7587).

  alias ExRTP.Packet

  @behaviour ExWebRTC.RTP.Depayloader.Behaviour

  @type t :: %__MODULE__{}

  defstruct []

  @impl true
  @spec new() :: t()
  def new() do
    %__MODULE__{}
  end

  @impl true
  @spec depayload(t(), Packet.t()) :: {binary(), t()}
  def depayload(%__MODULE__{} = depayloader, %Packet{payload: payload}),
    do: {payload, depayloader}
end
