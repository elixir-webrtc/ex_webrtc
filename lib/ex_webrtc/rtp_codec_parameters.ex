defmodule ExWebRTC.RTPCodecParameters do
  @moduledoc """
  Implementation of the [RTCRtpCodecParameters](https://www.w3.org/TR/webrtc/#rtcrtpcodecparameters).
  """

  alias ExSDP.Attribute.{FMTP, RTPMapping, RTCPFeedback}

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
