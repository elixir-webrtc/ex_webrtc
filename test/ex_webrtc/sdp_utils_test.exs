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

  describe "get_max_message_size/1" do
    test "returns value from the data mline" do
      assert 262_144 == SDPUtils.get_max_message_size(data_sdp("a=max-message-size:262144"))
      assert 0 == SDPUtils.get_max_message_size(data_sdp("a=max-message-size:0"))
    end

    test "returns nil when the attribute is missing or invalid" do
      assert nil == SDPUtils.get_max_message_size(data_sdp(""))
      assert nil == SDPUtils.get_max_message_size(data_sdp("a=max-message-size:abc"))
      assert nil == SDPUtils.get_max_message_size(data_sdp("a=max-message-size:-1"))
    end

    test "returns nil when there is no data mline" do
      {:ok, sdp} =
        """
        m=audio 9 UDP/TLS/RTP/SAVPF 111
        a=mid:0
        a=max-message-size:1024
        """
        |> ExSDP.parse()

      assert nil == SDPUtils.get_max_message_size(sdp)
    end
  end

  defp data_sdp(max_message_size_attr) do
    {:ok, sdp} =
      """
      m=audio 9 UDP/TLS/RTP/SAVPF 111
      a=mid:0
      m=application 9 UDP/DTLS/SCTP webrtc-datachannel
      a=mid:1
      a=sctp-port:5000
      #{max_message_size_attr}
      """
      |> ExSDP.parse()

    sdp
  end
end
