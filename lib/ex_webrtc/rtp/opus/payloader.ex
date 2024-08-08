defmodule ExWebRTC.RTP.Payloader.Opus do
  @moduledoc false
  # Encapsulates Opus audio packet into an RTP packet.
  #
  # Based on [RFC 7587: RTP Payload Format for the Opus Speech and Audio Codec](https://datatracker.ietf.org/doc/html/rfc7587).

  @behaviour ExWebRTC.RTP.Payloader.Behaviour

  @type t :: %__MODULE__{}

  defstruct []

  @impl true
  def new(_max_payload_size) do
    %__MODULE__{}
  end

  @impl true
  @spec payload(t(), binary()) :: {[ExRTP.Packet.t()], t()}
  def payload(%__MODULE__{} = payloader, packet) when packet != <<>> do
    {[ExRTP.Packet.new(packet)], payloader}
  end
end
