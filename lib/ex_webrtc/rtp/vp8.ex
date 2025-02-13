defmodule ExWebRTC.RTP.VP8 do
  @moduledoc """
  Utilities for RTP packets carrying VP8 encoded payload.
  """

  alias ExRTP.Packet
  alias ExWebRTC.RTP.VP8

  @doc """
  Checks whether RTP payload contains VP8 keyframe.
  """
  @spec keyframe?(Packet.t()) :: boolean()
  def keyframe?(%Packet{payload: rtp_payload}) do
    # RTP payload contains VP8 keyframe when P bit in VP8 payload header is set to 0
    # besides this S bit (start of VP8 partition) and PID (partition index)
    # have to be 1 and 0 respectively
    # for more information refer to RFC 7741 Sections 4.2 and 4.3

    with {:ok, vp8_payload} <- VP8.Payload.parse(rtp_payload),
         <<_size0::3, _h::1, _ver::3, p::1, _size1::8, _size2::8, _rest::binary>> <- rtp_payload do
      vp8_payload.s == 1 and vp8_payload.pid == 0 and p == 0
    else
      _err -> false
    end
  end
end
