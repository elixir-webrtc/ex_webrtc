defmodule ExWebRTC.MediaStreamTrack do
  @moduledoc """
  Mimics [MediaStreamTrack](https://www.w3.org/TR/mediacapture-streams/#dom-mediastreamtrack).
  """

  alias ExWebRTC.Utils

  @type id() :: integer()
  @type stream_id() :: String.t()
  @type kind() :: :audio | :video

  @type t() :: %__MODULE__{
          kind: kind(),
          id: id(),
          streams: [stream_id()]
        }

  @enforce_keys [:id, :kind]
  defstruct @enforce_keys ++ [streams: []]

  @spec new(kind()) :: t()
  def new(kind, streams \\ []) when kind in [:audio, :video] do
    %__MODULE__{kind: kind, id: Utils.generate_id(), streams: streams}
  end

  @spec generate_stream_id() :: stream_id()
  def generate_stream_id() do
    20
    |> :crypto.strong_rand_bytes()
    |> Base.encode32()
  end
end
