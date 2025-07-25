defmodule ExWebRTC.RTP.H264 do
  @moduledoc """
  Utilities for RTP packets carrying H264 encoded payload.
  """

  alias ExRTP.Packet

  # Copied nearly 1-to-1 from https://github.com/membraneframework/membrane_rtp_h264_plugin/blob/master/lib/rtp_h264/utils.ex
  # originally based on galene's implementation https://github.com/jech/galene/blob/6fbdf0eab2c9640e673d9f9ec0331da24cbf2c4c/codecs/codecs.go#L119
  # but only looks for SPS, in packetization_mode=0 as well as packetization_mode=1.
  #
  # It's been empirically tested with simulated packet loss that for packetization_mode=0 (`nalu_type in 1..23` clause):
  # * if we're checking against `nalu_type == 5`, the stream breaks regularly when switching layers,
  # * if we're checking against `nalu_type == 5 or nalu_type == 7`, the stream breaks occasionally when switching layers,
  #   this happens when we've lost the packet containing SPS, but received the following one containing the keyframe,
  # * if we're checking against `nalu_type == 7`, no issues were encountered.
  #
  # Janus also does it this way.
  # https://github.com/meetecho/janus-gateway/blob/3367f41de9225daed812ca0991c259f1458fe49f/src/utils.h#L352
  #
  # For more info, refer to the H264 spec and RFC 6184, sections 5.4 and 6
  # https://datatracker.ietf.org/doc/html/rfc6184#section-5.4

  @doc """
  Returns a boolean telling if the packets contains a beginning of a H264 intra-frame.
  """
  @spec keyframe?(Packet.t()) :: boolean()
  def keyframe?(%Packet{payload: <<_f::1, _nri::2, nalu_type::5, rest::binary>>}),
    do: do_keyframe?(nalu_type, rest)

  def keyframe?(%Packet{}), do: false

  # Reserved
  defp do_keyframe?(0, _), do: false

  # Single NAL Unit packets: check if NALU contains SPS (type 7)
  defp do_keyframe?(nalu_type, _) when nalu_type in 1..23, do: nalu_type == 7

  # STAP-A
  defp do_keyframe?(24, aus), do: check_aggr_units(24, aus)

  # STAP-B, MTAP16, MTAP24
  defp do_keyframe?(nalu_type, <<_don::16, aus::binary>>)
       when nalu_type in 25..27,
       do: check_aggr_units(nalu_type, aus)

  # FU-A, FU-B
  defp do_keyframe?(nalu_type, <<s::1, _e::1, _r::1, type::5, _fu_payload::binary>>)
       when nalu_type in 28..29,
       do: s == 1 and type == 7

  defp do_keyframe?(_, _), do: false

  defp check_aggr_units(nalu_type, aus) do
    offset = get_offset(nalu_type)

    case aus do
      <<size::16, _x::binary-size(offset), nalu::binary-size(size), rem_aus::binary>> ->
        if sps?(nalu), do: true, else: check_aggr_units(nalu_type, rem_aus)

      _other ->
        false
    end
  end

  defp sps?(<<0::1, _nal_ref_idc::2, type::5, _rest::binary>>), do: type == 7
  defp sps?(_other), do: false

  defp get_offset(26), do: 3
  defp get_offset(27), do: 4
  defp get_offset(_other), do: 0
end
