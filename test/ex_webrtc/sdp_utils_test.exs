defmodule ExWebRTC.SDPUtilsTest do
  use ExUnit.Case, async: true

  alias ExWebRTC.SDPUtils

  test "rejected?/1" do
    mline = ExSDP.Media.new(:audio, 0, "UDP/TLS/RTP/SAVPF", [8])
    assert true == SDPUtils.rejected?(mline)

    mline = ExSDP.Media.new(:audio, 9, "UDP/TLS/RTP/SAVPF", [8])
    assert false == SDPUtils.rejected?(mline)

    mline =
      ExSDP.Media.new(:audio, 0, "UDP/TLS/RTP/SAVPF", [8])
      |> ExSDP.add_attribute("bundle-only")

    assert false == SDPUtils.rejected?(mline)
  end

  test "get_ssrc_to_mid/1" do
    {:ok, sdp} =
      """
      m=video 50212 UDP/TLS/RTP/SAVPF 96 97
      a=mid:0
      a=ssrc:2343971353 cname:AmuRgxs+9JzwkmSG
      a=ssrc:3984689052 cname:AmuRgxs+9JzwkmSG
      m=audio 9 UDP/TLS/RTP/SAVPF 111
      a=mid:1
      a=ssrc:341204668 cname:AmuRgxs+9JzwkmSG
      """
      |> ExSDP.parse()

    ssrc_to_mids = SDPUtils.get_ssrc_to_mid(sdp)
    assert ssrc_to_mids == %{341_204_668 => "1", 2_343_971_353 => "0", 3_984_689_052 => "0"}
  end
end
