defmodule ExWebRTC.RTPCodecParameters do
  @moduledoc """
  Implementation of the [RTCRtpCodecParameters](https://www.w3.org/TR/webrtc/#rtcrtpcodecparameters).
  """

  alias ExSDP.Attribute.{FMTP, RTPMapping, RTCPFeedback}

  @typedoc """
  RTP codec parameters.

  * `payload_type` - payload type used to identify the codec.
  Keep in mind that the actual payload type depends on who sends the SDP offer first.
  If the browser sends it first and uses a different payload type for the same codec, 
  Elixir WebRTC will override its settings and use the payload type provided by the browser.
  If Elixir WebRTC sends the offert first and uses a different payload type for the same codec, 
  the browser will override its settings and use the payload type provided by Elixir WebRTC.

  For the meanings of the other fields, refer to the [MDN documentation](https://developer.mozilla.org/en-US/docs/Web/API/RTCRtpSender/getParameters#codecs)
  """
  @type t() :: %__MODULE__{
          payload_type: non_neg_integer(),
          mime_type: binary(),
          clock_rate: non_neg_integer(),
          channels: non_neg_integer() | nil,
          sdp_fmtp_line: ExSDP.Attribute.FMTP.t() | nil,
          rtcp_fbs: [ExSDP.Attribute.RTCPFeedback.t()]
        }

  @enforce_keys [:payload_type, :mime_type, :clock_rate]
  defstruct @enforce_keys ++ [:channels, :sdp_fmtp_line, rtcp_fbs: []]

  @spec new(:audio | :video, RTPMapping.t(), FMTP.t() | nil, [RTCPFeedback.t()]) :: t()
  def new(type, rtp_mapping, fmtp, rtcp_fbs) do
    %__MODULE__{
      payload_type: rtp_mapping.payload_type,
      mime_type: "#{type}/#{rtp_mapping.encoding}",
      clock_rate: rtp_mapping.clock_rate,
      channels: rtp_mapping.params,
      sdp_fmtp_line: fmtp,
      rtcp_fbs: rtcp_fbs
    }
  end
end
