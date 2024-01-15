defmodule ExWebRTC.RTPReceiver do
  @moduledoc """
  Implementation of the [RTCRtpReceiver](https://www.w3.org/TR/webrtc/#rtcrtpreceiver-interface).
  """

  alias ExWebRTC.MediaStreamTrack

  @type t() :: %__MODULE__{
          track: MediaStreamTrack.t() | nil
        }

  defstruct [:track]
end
