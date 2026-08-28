defmodule ExWebRTC.RTPSender.ReportRecorderTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias ExWebRTC.RTPSender.ReportRecorder

  @rand_ts System.os_time(:native)
  @seq_no 11_534
  @rtp_ts 234_444
  @clock_rate 90_000
  @packet ExRTP.Packet.new(<<>>, sequence_number: @seq_no, timestamp: @rtp_ts)
  @recorder ReportRecorder.init(%ReportRecorder{}, @clock_rate, 123_467)

  @ntp_offset 2_208_988_800
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

  describe "get_rtt/3" do
    setup do
      recorder =
        @recorder
        |> ReportRecorder.record_packet(@packet, @rand_ts)

      {:ok, recorder: recorder}
    end

    test "computes RTT from a report block referencing our last SR", %{recorder: recorder} do
      send_mono = System.monotonic_time()
      {:ok, sr, recorder} = ReportRecorder.get_report(recorder, @rand_ts, send_mono)

      lsr = sr.ntp_timestamp >>> 16 &&& @max_u32

      # remote held the report for 20 ms, network took 80 ms total
      dlsr = round(0.020 * 65_536)
      arrival = send_mono + System.convert_time_unit(100, :millisecond, :native)

      block = report_block(lsr: lsr, delay: dlsr)

      assert {:ok, rtt} = ReportRecorder.get_rtt(recorder, block, arrival)
      assert_in_delta rtt, 0.080, 0.001
    end

    test "matches an older SR, not only the newest one", %{recorder: recorder} do
      mono0 = System.monotonic_time()
      {:ok, sr0, recorder} = ReportRecorder.get_report(recorder, @rand_ts, mono0)

      t1 = @rand_ts + System.convert_time_unit(1000, :millisecond, :native)
      mono1 = mono0 + System.convert_time_unit(1000, :millisecond, :native)
      {:ok, _sr1, recorder} = ReportRecorder.get_report(recorder, t1, mono1)

      lsr0 = sr0.ntp_timestamp >>> 16 &&& @max_u32
      arrival = mono0 + System.convert_time_unit(150, :millisecond, :native)
      block = report_block(lsr: lsr0, delay: round(0.050 * 65_536))

      assert {:ok, rtt} = ReportRecorder.get_rtt(recorder, block, arrival)
      assert_in_delta rtt, 0.100, 0.001
    end

    test "keeps at most 5 sent reports", %{recorder: recorder} do
      mono0 = System.monotonic_time()

      {:ok, sr0, recorder} =
        Enum.reduce(0..5, {nil, recorder}, fn i, {first, rec} ->
          time = @rand_ts + System.convert_time_unit(i * 1000, :millisecond, :native)
          mono = mono0 + System.convert_time_unit(i * 1000, :millisecond, :native)
          {:ok, sr, rec} = ReportRecorder.get_report(rec, time, mono)
          {first || sr, rec}
        end)
        |> then(fn {sr, rec} -> {:ok, sr, rec} end)

      assert length(recorder.sent_reports) == 5

      lsr0 = sr0.ntp_timestamp >>> 16 &&& @max_u32
      block = report_block(lsr: lsr0, delay: 100)

      assert {:error, :no_matching_report} =
               ReportRecorder.get_rtt(recorder, block, mono0)
    end

    test "refuses a block from a peer that received no SR yet", %{recorder: recorder} do
      {:ok, _sr, recorder} = ReportRecorder.get_report(recorder, @rand_ts)
      mono = System.monotonic_time()

      assert {:error, :no_last_sr} =
               ReportRecorder.get_rtt(recorder, report_block(lsr: 0, delay: 0), mono)

      assert {:error, :no_last_sr} =
               ReportRecorder.get_rtt(recorder, report_block(lsr: 123, delay: 0), mono)
    end

    test "clamps an anachronous report to zero", %{recorder: recorder} do
      send_mono = System.monotonic_time()
      {:ok, sr, recorder} = ReportRecorder.get_report(recorder, @rand_ts, send_mono)
      lsr = sr.ntp_timestamp >>> 16 &&& @max_u32

      # remote claims to have held the report far longer than the elapsed time
      dlsr = round(5.0 * 65_536)
      arrival = send_mono + System.convert_time_unit(10, :millisecond, :native)

      assert {:ok, +0.0} =
               ReportRecorder.get_rtt(recorder, report_block(lsr: lsr, delay: dlsr), arrival)
    end

    test "errors when we have sent no report at all", %{recorder: recorder} do
      assert {:error, :no_matching_report} =
               ReportRecorder.get_rtt(
                 recorder,
                 report_block(lsr: 1, delay: 1),
                 System.monotonic_time()
               )
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
end
