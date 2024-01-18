defmodule ExWebRTC.SDPUtilsTest do
  use ExUnit.Case, async: true

  alias ExWebRTC.SDPUtils

  test "rejected?/1" do
    mline = ExSDP.Media.new(:audio, 0, "UDP/TLS/RTP/SAVPF", [8])
    assert true == SDPUtils.rejected?(mline)

    mline = ExSDP.Media.new(:audio, 9, "UDP/TLS/RTP/SAVPF", [8])
    assert false == SDPUtils.rejected?(mline)
  end
end
