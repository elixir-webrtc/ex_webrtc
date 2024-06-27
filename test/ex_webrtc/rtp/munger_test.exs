defmodule ExWebRTC.RTP.MungerTest do
  use ExUnit.Case, async: true

  alias ExRTP.Packet
  alias ExWebRTC.RTP.Munger

  @clock_rate 90_000
  @packet Packet.new(<<0::128*8>>)

  @tag :wip
  test "munges packets properly" do
    munger = Munger.new(@clock_rate)
    {_munger, _packet} = Munger.munge(munger, @packet)
  end

  test "handles sequence number rollover" do
  end

  test "handles timestamp rollover" do
  end
end
