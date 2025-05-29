defmodule ExWebRTC.RTP.Depayloader.Opus do
  @moduledoc false
  # Decapsulates Opus audio out of RTP packet.
  #
  # Based on [RFC 7587: RTP Payload Format for the Opus Speech and Audio Codec](https://datatracker.ietf.org/doc/html/rfc7587).

  alias ExRTP.Packet

  @behaviour ExWebRTC.RTP.Depayloader.Behaviour

  @type t :: %__MODULE__{}

  defstruct []

  @impl true
  def new() do
    %__MODULE__{}
  end

  @impl true
  def depayload(%__MODULE__{} = depayloader, %Packet{payload: payload}),
    do: {payload, depayloader}
end
