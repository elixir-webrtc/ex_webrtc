defmodule ExWebRTC.MediaStreamTrack do
  @moduledoc """
  Mimics [MediaStreamTrack](https://www.w3.org/TR/mediacapture-streams/#dom-mediastreamtrack).
  """

  alias ExWebRTC.SDPUtils
  alias ExWebRTC.Utils

  @type id() :: integer()
  @type stream_id() :: String.t()
  @type rid() :: String.t()
  @type kind() :: :audio | :video

  @type t() :: %__MODULE__{
          kind: kind(),
          id: id(),
          streams: [stream_id()],
          rids: [rid()] | nil
        }

  @enforce_keys [:id, :kind]
  defstruct @enforce_keys ++ [streams: [], rids: nil]

  @spec new(kind(), [stream_id()]) :: t()
  def new(kind, streams \\ []) when kind in [:audio, :video] do
    %__MODULE__{kind: kind, id: Utils.generate_id(), streams: streams}
  end

  @doc false
  @spec from_mline(ExSDP.Media.t()) :: t()
  def from_mline(mline) do
    streams = SDPUtils.get_stream_ids(mline)
    rids = SDPUtils.get_rids(mline)
    %__MODULE__{kind: mline.type, id: Utils.generate_id(), streams: streams, rids: rids}
  end

  @spec generate_stream_id() :: stream_id()
  def generate_stream_id() do
    20
    |> :crypto.strong_rand_bytes()
    |> Base.encode32()
  end
end
