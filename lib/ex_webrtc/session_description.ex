defmodule ExWebRTC.SessionDescription do
  @moduledoc """
  Implementation of the [RTCSessionDescription](https://www.w3.org/TR/webrtc/#rtcsessiondescription-class).
  """

  @type description_type() ::
          :answer
          | :offer
          | :pranswer
          | :rollback

  @type t() :: %__MODULE__{
          type: description_type(),
          sdp: String.t()
        }

  @enforce_keys [:type, :sdp]
  defstruct @enforce_keys

  @spec to_json(t()) :: %{String.t() => String.t()}
  def to_json(%__MODULE__{} = sd) do
    %{
      "type" => Atom.to_string(sd.type),
      "sdp" => sd.sdp
    }
  end

  @spec from_json(%{String.t() => String.t()}) :: t()
  def from_json(%{"type" => type, "sdp" => sdp})
      when type in ~w(answer offer pranswer rollback) do
    %__MODULE__{type: String.to_atom(type), sdp: sdp}
  end
end
