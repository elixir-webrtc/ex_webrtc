defmodule ExWebRTC.ICECandidate do
  @moduledoc """
  Implementation of the [RTCIceCandidate](https://www.w3.org/TR/webrtc/#rtcicecandidate-interface).
  """

  @type t() :: %__MODULE__{
          candidate: binary(),
          sdp_mid: binary() | nil,
          sdp_m_line_index: non_neg_integer() | nil,
          username_fragment: binary() | nil
        }

  defstruct [:candidate, :username_fragment, :sdp_mid, :sdp_m_line_index]

  @spec to_json(t()) :: %{String.t() => String.t() | non_neg_integer() | nil}
  def to_json(%__MODULE__{} = c) do
    %{
      "candidate" => c.candidate,
      "sdpMid" => c.sdp_mid,
      "sdpMLineIndex" => c.sdp_m_line_index,
      "usernameFragment" => c.username_fragment
    }
  end

  @spec from_json(%{String.t() => String.t() | non_neg_integer() | nil}) :: t()
  def from_json(
        %{
          "candidate" => c,
          "sdpMid" => mid,
          "sdpMLineIndex" => mline_idx
        } = json
      ) do
    from_json(Map.put(json, "usernameFragment", nil))
  end

  def from_json(%{
        "candidate" => c,
        "sdpMid" => mid,
        "sdpMLineIndex" => mline_idx,
        "usernameFragment" => ufrag
      }) do
    %__MODULE__{
      candidate: c,
      sdp_mid: mid,
      sdp_m_line_index: mline_idx,
      username_fragment: ufrag
    }
  end
end
