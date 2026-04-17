defmodule ExWebRTC.PeerConnection.TWCCSendLogTest do
  use ExUnit.Case, async: true

  alias ExWebRTC.PeerConnection.TWCCSendLog

  @seq_no 100
  @size 1200

  describe "new/0" do
    test "creates empty log" do
      log = TWCCSendLog.new()
      assert TWCCSendLog.to_map(log) == %{}
    end
  end

  describe "record_packet/4" do
    test "records a single packet" do
      now = System.monotonic_time(:microsecond)
      log = TWCCSendLog.new() |> TWCCSendLog.record_packet(@seq_no, now, @size)

      assert TWCCSendLog.to_map(log) == %{@seq_no => {now, @size}}
    end

    test "records multiple sequential packets" do
      now = System.monotonic_time(:microsecond)

      log =
        TWCCSendLog.new()
        |> TWCCSendLog.record_packet(@seq_no, now, @size)
        |> TWCCSendLog.record_packet(@seq_no + 1, now + 1000, @size)
        |> TWCCSendLog.record_packet(@seq_no + 2, now + 2000, @size)

      map = TWCCSendLog.to_map(log)

      assert map_size(map) == 3
      assert map[@seq_no] == {now, @size}
      assert map[@seq_no + 1] == {now + 1000, @size}
      assert map[@seq_no + 2] == {now + 2000, @size}
    end

    test "records packets with different sizes" do
      now = System.monotonic_time(:microsecond)

      log =
        TWCCSendLog.new()
        |> TWCCSendLog.record_packet(@seq_no, now, 100)
        |> TWCCSendLog.record_packet(@seq_no + 1, now + 1000, 500)

      map = TWCCSendLog.to_map(log)

      assert map[@seq_no] == {now, 100}
      assert map[@seq_no + 1] == {now + 1000, 500}
    end
  end

  describe "eviction" do
    test "evicts packets older than 2 seconds" do
      old_time = System.monotonic_time(:microsecond) - 3_000_000
      now = System.monotonic_time(:microsecond)

      log =
        TWCCSendLog.new()
        |> TWCCSendLog.record_packet(@seq_no, old_time, @size)
        |> TWCCSendLog.record_packet(@seq_no + 1, old_time + 100, @size)
        |> TWCCSendLog.record_packet(@seq_no + 2, now, @size)

      map = TWCCSendLog.to_map(log)

      refute Map.has_key?(map, @seq_no)
      refute Map.has_key?(map, @seq_no + 1)
      assert Map.has_key?(map, @seq_no + 2)
    end

    test "keeps packets within the 2-second window" do
      now = System.monotonic_time(:microsecond)

      log =
        TWCCSendLog.new()
        |> TWCCSendLog.record_packet(@seq_no, now - 1_500_000, @size)
        |> TWCCSendLog.record_packet(@seq_no + 1, now, @size)

      map = TWCCSendLog.to_map(log)
      assert map_size(map) == 2
    end
  end

  describe "seq_no wrapping" do
    test "handles 16-bit seq_no values near the boundary" do
      now = System.monotonic_time(:microsecond)

      log =
        TWCCSendLog.new()
        |> TWCCSendLog.record_packet(0xFFFE, now, @size)
        |> TWCCSendLog.record_packet(0xFFFF, now + 1000, @size)
        |> TWCCSendLog.record_packet(0, now + 2000, @size)
        |> TWCCSendLog.record_packet(1, now + 3000, @size)

      map = TWCCSendLog.to_map(log)

      assert map_size(map) == 4
      assert map[0xFFFE] == {now, @size}
      assert map[0xFFFF] == {now + 1000, @size}
      assert map[0] == {now + 2000, @size}
      assert map[1] == {now + 3000, @size}
    end
  end
end
