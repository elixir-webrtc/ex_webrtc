defmodule ExWebRTC.RTPSender.ReportRecorderTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias ExWebRTC.RTPSender.ReportRecorder

  @rand_ts System.os_time(:native)
  @seq_no 11_534
  @rtp_ts 234_444
  @clock_rate 90_000
  @ntp_offset 2_208_988_800
  @packet ExRTP.Packet.new(<<>>, sequence_number: @seq_no, timestamp: @rtp_ts)
  @recorder ReportRecorder.init(%ReportRecorder{}, @clock_rate, 123_467)
  @max_u32 0xFFFFFFFF

  test "init/3" do
    recorder = %ReportRecorder{}

    %{clock_rate: 90_000, sender_ssrc: 1234} =
      recorder = ReportRecorder.init(recorder, 90_000, 1234)

    assert_raise RuntimeError, fn -> ReportRecorder.init(recorder, 90_000, 1234) end
  end

  describe "record_packet/3" do
    test "keeps track of packet counts and sizes" do
      recorder =
        @recorder
        |> ReportRecorder.record_packet(@packet, @rand_ts)
        |> ReportRecorder.record_packet(%{@packet | payload: <<1, 2, 3>>}, @rand_ts)
        |> ReportRecorder.record_packet(%{@packet | payload: <<1, 2, 3, 4, 5>>}, @rand_ts)

      assert %ReportRecorder{
               packet_count: 3,
               octet_count: 8
             } = recorder
    end

    test "remembers last timestamps" do
      last_ts = @rand_ts - 100

      recorder =
        @recorder
        |> ReportRecorder.record_packet(
          %{@packet | timestamp: @rtp_ts - 200, sequence_number: @seq_no - 2},
          @rand_ts - 200
        )
        |> ReportRecorder.record_packet(@packet, last_ts)
        |> ReportRecorder.record_packet(
          %{@packet | timestamp: @rtp_ts - 100, sequence_number: @seq_no - 1},
          @rand_ts
        )

      assert %ReportRecorder{
               last_rtp_timestamp: @rtp_ts,
               last_seq_no: @seq_no,
               last_timestamp: ^last_ts
             } = recorder
    end

    test "handles wrapping sequence numbers" do
      recorder =
        @recorder
        |> ReportRecorder.record_packet(%{@packet | sequence_number: 65_534}, @rand_ts - 300)
        |> ReportRecorder.record_packet(%{@packet | sequence_number: 65_535}, @rand_ts - 200)
        |> ReportRecorder.record_packet(%{@packet | sequence_number: 0}, @rand_ts - 100)
        |> ReportRecorder.record_packet(%{@packet | sequence_number: 1}, @rand_ts)

      assert %ReportRecorder{
               last_seq_no: 1,
               last_timestamp: @rand_ts
             } = recorder
    end
  end

  describe "get_report/2" do
    test "properly calculates NTP timestamp" do
      assert {:ok, report, _recorder} =
               @recorder
               |> ReportRecorder.record_packet(@packet, 0)
               |> ReportRecorder.get_report(0)

      assert report.ntp_timestamp >>> 32 == @ntp_offset
      assert (report.ntp_timestamp &&& @max_u32) == 0

      native_in_sec = System.convert_time_unit(1, :second, :native)
      seconds = 89_934
      # 1/8, so 0.001 in binary
      frac = 0.125

      assert {:ok, report, _recorder} =
               @recorder
               |> ReportRecorder.record_packet(@packet, 0)
               |> ReportRecorder.get_report(trunc((seconds + frac) * native_in_sec))

      assert report.ntp_timestamp >>> 32 == @ntp_offset + seconds
      assert (report.ntp_timestamp &&& @max_u32) == 1 <<< 29
    end

    test "properly calculates delay since last packet" do
      delta = System.convert_time_unit(250, :millisecond, :native)

      assert {:ok, report, _recorder} =
               @recorder
               |> ReportRecorder.record_packet(@packet, @rand_ts)
               |> ReportRecorder.get_report(@rand_ts + delta)

      assert report.rtp_timestamp == @rtp_ts + 0.25 * @clock_rate
    end
  end

  describe "get_rtt/2" do
    setup do
      {:ok, recorder: ReportRecorder.record_packet(@recorder, @packet, @rand_ts)}
    end

    test "computes RTT from a report block referencing our SR", %{recorder: recorder} do
      {:ok, sr, _recorder} = ReportRecorder.get_report(recorder, @rand_ts)
      lsr = compact_ntp(sr.ntp_timestamp)

      # remote held the report for 20 ms, 100 ms elapsed in total
      dlsr = round(0.020 * 65_536)
      arrival = @rand_ts + System.convert_time_unit(100, :millisecond, :native)

      assert {:ok, rtt} = ReportRecorder.get_rtt(report_block(lsr: lsr, delay: dlsr), arrival)
      assert_in_delta rtt, 0.080, 0.001
    end

    test "computes RTT against an older SR, not only the newest one", %{recorder: recorder} do
      {:ok, sr0, recorder} = ReportRecorder.get_report(recorder, @rand_ts)

      t1 = @rand_ts + System.convert_time_unit(1000, :millisecond, :native)
      {:ok, _sr1, _recorder} = ReportRecorder.get_report(recorder, t1)

      lsr0 = compact_ntp(sr0.ntp_timestamp)
      arrival = @rand_ts + System.convert_time_unit(150, :millisecond, :native)
      block = report_block(lsr: lsr0, delay: round(0.050 * 65_536))

      assert {:ok, rtt} = ReportRecorder.get_rtt(block, arrival)
      assert_in_delta rtt, 0.100, 0.001
    end

    test "stays correct across the compact NTP rollover", %{recorder: recorder} do
      # the next wall-clock instant at which the compact NTP value wraps to zero
      wrap_s = (div(System.os_time(:second) + @ntp_offset, 65_536) + 1) * 65_536 - @ntp_offset
      wrap = System.convert_time_unit(wrap_s, :second, :native)

      # our SR goes out 100 ms before the wrap
      sr_time = wrap - System.convert_time_unit(100, :millisecond, :native)
      {:ok, sr, _recorder} = ReportRecorder.get_report(recorder, sr_time)

      lsr = compact_ntp(sr.ntp_timestamp)
      assert lsr > 0xFFFF_0000

      # and the block comes back 50 ms after it, so 150 ms elapsed, 30 ms held
      arrival = wrap + System.convert_time_unit(50, :millisecond, :native)
      block = report_block(lsr: lsr, delay: round(0.030 * 65_536))

      assert {:ok, rtt} = ReportRecorder.get_rtt(block, arrival)
      assert_in_delta rtt, 0.120, 0.001
    end

    test "refuses a block from a peer that received no SR yet" do
      assert {:error, :no_last_sr} = ReportRecorder.get_rtt(report_block(lsr: 0, delay: 0))
      assert {:error, :no_last_sr} = ReportRecorder.get_rtt(report_block(lsr: 123, delay: 0))
    end

    test "clamps an anachronous report to zero", %{recorder: recorder} do
      {:ok, sr, _recorder} = ReportRecorder.get_report(recorder, @rand_ts)
      lsr = compact_ntp(sr.ntp_timestamp)

      # remote claims to have held the report far longer than the elapsed time
      dlsr = round(5.0 * 65_536)
      arrival = @rand_ts + System.convert_time_unit(10, :millisecond, :native)

      assert {:ok, +0.0} = ReportRecorder.get_rtt(report_block(lsr: lsr, delay: dlsr), arrival)
    end

    test "rejects a block read back after our clock moved backwards", %{recorder: recorder} do
      {:ok, sr, _recorder} = ReportRecorder.get_report(recorder, @rand_ts)
      lsr = compact_ntp(sr.ntp_timestamp)

      # our wall clock stepped back 1 ms after we sent the report; without the
      # bound the masked subtraction aliases to ~18 h instead of a negative
      arrival = @rand_ts - System.convert_time_unit(1, :millisecond, :native)

      assert {:error, :invalid_last_sr} =
               ReportRecorder.get_rtt(report_block(lsr: lsr, delay: 1), arrival)
    end

    test "rejects a last_sr pointing implausibly far back", %{recorder: recorder} do
      {:ok, sr, _recorder} = ReportRecorder.get_report(recorder, @rand_ts)
      lsr = compact_ntp(sr.ntp_timestamp)

      arrival = @rand_ts + System.convert_time_unit(60, :second, :native)

      assert {:error, :invalid_last_sr} =
               ReportRecorder.get_rtt(report_block(lsr: lsr, delay: 1), arrival)
    end
  end

  defp report_block(opts) do
    %ExRTCP.Packet.ReceptionReport{
      ssrc: 123_467,
      fraction_lost: 0,
      total_lost: 0,
      last_sequence_number: 0,
      jitter: 0,
      last_sr: Keyword.fetch!(opts, :lsr),
      delay: Keyword.fetch!(opts, :delay)
    }
  end

  # the middle 32 bits of the NTP timestamp
  defp compact_ntp(ntp_timestamp), do: ntp_timestamp >>> 16 &&& 0xFFFFFFFF
end
