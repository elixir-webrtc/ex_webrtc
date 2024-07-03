defmodule ExWebRTC.RTP.MungerTest do
  use ExUnit.Case, async: true

  alias ExRTP.Packet
  alias ExWebRTC.RTP.Munger

  @max_sn 0xFFFF
  @max_ts 0xFFFFFFFF

  @clock_rate 90_000
  @packet Packet.new(<<0::128*8>>)

  test "assigns sequence numbers properly" do
    munger = Munger.new(@clock_rate)

    l1_packet = %{@packet | sequence_number: 100}
    {^l1_packet, munger} = Munger.munge(munger, l1_packet)

    l1_packet = %{@packet | sequence_number: 101}
    {^l1_packet, munger} = Munger.munge(munger, l1_packet)

    # this may be considered as invalid
    # after the encoding change (I also consider the initial packet as a first packet after an
    # encoding change) we could want to ignore packets with seq_num < seq_num of the first packet
    # in order to not conflict with packets from the previous encoding
    l1_packet = %{@packet | sequence_number: 98}
    {^l1_packet, munger} = Munger.munge(munger, l1_packet)

    munger = Munger.update(munger)

    # new encoding should start
    l2_packet = %{@packet | sequence_number: 20_001}
    {packet, munger} = Munger.munge(munger, l2_packet)
    assert packet.sequence_number == 102

    l2_packet = %{@packet | sequence_number: 20_004}
    {packet, munger} = Munger.munge(munger, l2_packet)
    assert packet.sequence_number == 105

    munger = Munger.update(munger)

    l3_packet = %{@packet | sequence_number: 3047}
    {packet, _munger} = Munger.munge(munger, l3_packet)
    assert packet.sequence_number == 106
  end

  test "handles input sequence number rollover" do
    munger = Munger.new(@clock_rate)

    l1_packet = %{@packet | sequence_number: 100}
    {^l1_packet, munger} = Munger.munge(munger, l1_packet)

    munger = Munger.update(munger)

    l2_packet = %{@packet | sequence_number: @max_sn - 1}
    {packet, munger} = Munger.munge(munger, l2_packet)
    assert packet.sequence_number == 101

    l2_packet = %{@packet | sequence_number: 0}
    {packet, munger} = Munger.munge(munger, l2_packet)
    assert packet.sequence_number == 103

    l2_packet = %{@packet | sequence_number: 1}
    {packet, munger} = Munger.munge(munger, l2_packet)
    assert packet.sequence_number == 104

    # lets rollover one more time, bc why not
    munger = Munger.update(munger)

    l3_packet = %{@packet | sequence_number: @max_sn}
    {packet, munger} = Munger.munge(munger, l3_packet)
    assert packet.sequence_number == 105

    l3_packet = %{@packet | sequence_number: 0}
    {packet, _munger} = Munger.munge(munger, l3_packet)
    assert packet.sequence_number == 106
  end

  test "handles output sequence number rollover" do
    munger = Munger.new(@clock_rate)

    l1_packet = %{@packet | sequence_number: @max_sn - 2}
    {^l1_packet, munger} = Munger.munge(munger, l1_packet)

    munger = Munger.update(munger)

    l2_packet = %{@packet | sequence_number: 100}
    {packet, munger} = Munger.munge(munger, l2_packet)
    assert packet.sequence_number == @max_sn - 1

    l2_packet = %{@packet | sequence_number: 101}
    {packet, munger} = Munger.munge(munger, l2_packet)
    assert packet.sequence_number == @max_sn

    l2_packet = %{@packet | sequence_number: 102}
    {packet, _munger} = Munger.munge(munger, l2_packet)
    assert packet.sequence_number == 0
  end

  test "assigns timestamps properly" do
    munger = Munger.new(@clock_rate)

    l1_packet = %{@packet | sequence_number: 100, timestamp: 5000}
    {^l1_packet, munger} = Munger.munge(munger, l1_packet)

    l1_packet = %{@packet | sequence_number: 101, timestamp: 6000}
    {^l1_packet, munger} = Munger.munge(munger, l1_packet)

    munger = Munger.update(munger)

    l2_packet = %{@packet | sequence_number: 1000, timestamp: 30}
    {packet, munger} = Munger.munge(munger, l2_packet)
    # the exact timestamp depends on the arrival timestamp of the packets
    # we assume here that time between function calls was < 1000 ts units ~ 10 ms
    # this test can be improved after we start using RTCP Sender Reports instead of current time
    assert packet.timestamp in 6001..7000
    ts = packet.timestamp

    l2_packet = %{@packet | sequence_number: 1001, timestamp: 730}
    {packet, munger} = Munger.munge(munger, l2_packet)
    assert packet.timestamp == ts + 700
    ts = packet.timestamp

    munger = Munger.update(munger)

    l3_packet = %{@packet | sequence_number: 50_000, timestamp: 96_011}
    {packet, munger} = Munger.munge(munger, l3_packet)
    assert packet.timestamp in (ts + 1)..(ts + 1000)
    ts = packet.timestamp

    l3_packet = %{@packet | sequence_number: 50_001, timestamp: 96_511}
    {packet, _munger} = Munger.munge(munger, l3_packet)
    assert packet.timestamp == ts + 500
  end

  test "handles input timestamp rollover" do
    munger = Munger.new(@clock_rate)

    l1_packet = %{@packet | sequence_number: 100, timestamp: 5000}
    {^l1_packet, munger} = Munger.munge(munger, l1_packet)

    munger = Munger.update(munger)

    l2_packet = %{@packet | sequence_number: 200, timestamp: @max_ts}
    {packet, munger} = Munger.munge(munger, l2_packet)
    assert packet.timestamp in 5001..6000
    ts = packet.timestamp

    l2_packet = %{@packet | sequence_number: 201, timestamp: 1000}
    {packet, _munger} = Munger.munge(munger, l2_packet)
    assert packet.timestamp == ts + 1001
  end

  test "handles output timestamp rollover" do
    munger = Munger.new(@clock_rate)

    l1_packet = %{@packet | sequence_number: 100, timestamp: @max_ts}
    {^l1_packet, munger} = Munger.munge(munger, l1_packet)

    munger = Munger.update(munger)

    l2_packet = %{@packet | sequence_number: 200, timestamp: 5000}
    {packet, _munger} = Munger.munge(munger, l2_packet)
    assert packet.timestamp < 1000
  end
end
