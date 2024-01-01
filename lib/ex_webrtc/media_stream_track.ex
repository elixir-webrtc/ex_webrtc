defmodule ExWebRTC.MediaStreamTrack do
  @moduledoc """
  MediaStreamTrack
  """

  alias ExWebRTC.Utils

  @type id() :: integer()

  @type t() :: %__MODULE__{
          kind: :audio | :video,
          id: id()
        }

  @enforce_keys [:id, :kind]
  defstruct @enforce_keys

  def new(kind) do
    %__MODULE__{kind: kind, id: Utils.generate_id()}
  end
end
