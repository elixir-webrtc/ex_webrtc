defmodule ExWebRTC.RTP.Payloader.G711 do
  @moduledoc false
  # Encapsulates G.711 audio packet into an RTP packet.
  #
  # Based in [RFC 3551: RTP Profile for Audio and Video Conferences with Minimal Control, section 4.5.14](https://datatracker.ietf.org/doc/html/rfc3551#section-4.5.14)

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
