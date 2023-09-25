defmodule ExWebRTC.IceCandidate do
  @moduledoc false

  # not exacly the same as W3 IceCandidate
  @type t() :: %__MODULE__{
          candidate: term() | nil,
          sdp_mid: term() | nil,
          sdp_m_line_index: term() | nil,
          username_fragment: term() | nil
        }

  defstruct [:candidate, :username_fragment, :sdp_mid, :sdp_m_line_index]
end
