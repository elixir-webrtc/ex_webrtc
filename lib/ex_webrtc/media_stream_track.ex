defmodule ExWebRTC.MediaStreamTrack do
  @moduledoc """
  MediaStreamTrack
  """

  @type t() :: %__MODULE__{
          kind: :audio | :video,
          id: integer(),
          mid: String.t()
        }

  @enforce_keys [:id, :kind]
  defstruct @enforce_keys ++ [:mid]

  def from_transceiver(tr) do
    %__MODULE__{kind: tr.kind, id: generate_id(), mid: tr.mid}
  end

  defp generate_id() do
    <<id::12*8>> = :crypto.strong_rand_bytes(12)
    id
  end
end
