defmodule ExWebRTC.MediaStreamTrack do
  @moduledoc """
  Mimics [MediaStreamTrack](https://www.w3.org/TR/mediacapture-streams/#dom-mediastreamtrack).
  """

  alias ExWebRTC.Utils

  @type id() :: integer()
  @type kind() :: :audio | :video

  @type t() :: %__MODULE__{
          kind: kind(),
          id: id()
        }

  @enforce_keys [:id, :kind]
  defstruct @enforce_keys

  @spec new(kind()) :: t()
  def new(kind) when kind in [:audio, :video] do
    %__MODULE__{kind: kind, id: Utils.generate_id()}
  end
end
