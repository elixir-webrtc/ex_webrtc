defmodule ExWebRTC.MediaStreamTrack do
  @moduledoc """
  MediaStreamTrack
  """

  @type t() :: %__MODULE__{
          kind: :audio | :video,
          id: integer()
        }

  @enforce_keys [:id, :kind]
  defstruct @enforce_keys

  def new(kind) do
    %__MODULE__{kind: kind, id: generate_id()}
  end

  defp generate_id() do
    <<id::12*8>> = :crypto.strong_rand_bytes(12)
    id
  end
end
