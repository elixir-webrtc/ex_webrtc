defmodule ExWebRTC.RTP.H264 do
  @moduledoc """
  Utilities for RTP Packets carrying H264 encoded payload.
  """

  alias ExRTP.Packet

  # Copied nearly 1-to-1 from https://github.com/membraneframework/membrane_rtp_h264_plugin/blob/master/lib/rtp_h264/utils.ex
  # but only looks for SPS
  # look there for explenations why it does what it does

  @doc """
  Returns a boolean telling if the packets contains a beginning of a H264 intra-frame.
  """
  @spec keyframe?(Packet.t()) :: boolean()
  def keyframe?(%Packet{payload: <<_f::1, _nri::2, nalu_type::5, rest::binary>>}),
    do: do_keyframe?(nalu_type, rest)

  def keyframe?(%Packet{}), do: false

  defp do_keyframe?(0, _), do: false
  defp do_keyframe?(nalu_type, _) when nalu_type in 1..23, do: nalu_type == 5
  defp do_keyframe?(24, aus), do: check_aggr_units(24, aus)

  defp do_keyframe?(nalu_type, <<_don::16, aus::binary>>)
       when nalu_type in 25..27,
       do: check_aggr_units(nalu_type, aus)

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
