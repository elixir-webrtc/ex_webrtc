defmodule ExWebRTC.ICECandidate do
  @moduledoc """
  Implementation of the [RTCIceCandidate](https://www.w3.org/TR/webrtc/#rtcicecandidate-interface).
  """

  @type t() :: %__MODULE__{
          candidate: binary(),
          sdp_mid: non_neg_integer() | nil,
          sdp_m_line_index: non_neg_integer() | nil,
          username_fragment: binary() | nil
        }

  defstruct [:candidate, :username_fragment, :sdp_mid, :sdp_m_line_index]
end
