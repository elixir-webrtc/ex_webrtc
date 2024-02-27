defmodule ExWebRTC.RTPSender.ReportRecorderTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias ExWebRTC.RTPSender.ReportRecorder

  @rand_ts System.os_time(:native)
  @seq_no 11_534
  @rtp_ts 234_444
  @clock_rate 90_000
  @packet ExRTP.Packet.new(<<>>, sequence_number: @seq_no, timestamp: @rtp_ts)
  @recorder %ReportRecorder{sender_ssrc: 123_467, clock_rate: @clock_rate}

  @ntp_offset 2_208_988_800
  @max_u32 0xFFFFFFFF

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
      report =
        @recorder
        |> ReportRecorder.record_packet(@packet, 0)
        |> ReportRecorder.get_report(0)

      assert report.ntp_timestamp >>> 32 == @ntp_offset
      assert (report.ntp_timestamp &&& @max_u32) == 0

      native_in_sec = System.convert_time_unit(1, :second, :native)
      seconds = 89_934
      # 1/8, so 0.001 in binary 
      frac = 0.125

      report =
        @recorder
        |> ReportRecorder.record_packet(@packet, 0)
        |> ReportRecorder.get_report(trunc((seconds + frac) * native_in_sec))

      assert report.ntp_timestamp >>> 32 == @ntp_offset + seconds
      assert (report.ntp_timestamp &&& @max_u32) == 1 <<< 29
    end

    test "properly calculates delay since last packet" do
      delta = System.convert_time_unit(250, :millisecond, :native)

      report =
        @recorder
        |> ReportRecorder.record_packet(@packet, @rand_ts)
        |> ReportRecorder.get_report(@rand_ts + delta)

      assert report.rtp_timestamp == @rtp_ts + 0.25 * @clock_rate
    end
  end
end
