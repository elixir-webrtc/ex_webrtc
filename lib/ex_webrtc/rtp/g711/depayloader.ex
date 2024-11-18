defmodule ExWebRTC.RTP.Depayloader.G711 do
  @moduledoc false
  # Decapsulates G.711 audio out of RTP packet.
  #
  # Based in [RFC 3551: RTP Profile for Audio and Video Conferences with Minimal Control, section 4.5.14](https://datatracker.ietf.org/doc/html/rfc3551#section-4.5.14)

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
