defmodule ExWebRTC.SDPUtilsTest do
  use ExUnit.Case, async: true

  alias ExWebRTC.SDPUtils

  test "is_rejected/1" do
    mline = ExSDP.Media.new(:audio, 0, "UDP/TLS/RTP/SAVPF", [8])
    assert true == SDPUtils.is_rejected(mline)

    mline = ExSDP.Media.new(:audio, 9, "UDP/TLS/RTP/SAVPF", [8])
    assert false == SDPUtils.is_rejected(mline)
  end
end
