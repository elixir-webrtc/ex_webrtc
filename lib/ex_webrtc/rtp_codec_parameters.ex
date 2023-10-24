defmodule ExWebRTC.RTPCodecParameters do
  @moduledoc """
  RTPCodecParameters
  """

  defstruct [:payload_type, :mime_type, :clock_rate, :channels, :sdp_fmtp_line, :rtcp_fbs]

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
