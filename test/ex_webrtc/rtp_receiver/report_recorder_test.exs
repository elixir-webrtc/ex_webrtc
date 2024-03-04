defmodule ExWebRTC.RTPReceiver.ReportRecorderTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias ExRTCP.Packet.{SenderReport, ReceiverReport, ReceptionReport}
  alias ExRTP.Packet
  alias ExWebRTC.RTPReceiver.ReportRecorder

  @rand_ts System.monotonic_time()
  @seq_no 11_534
  @rtp_ts 234_444
  @packet Packet.new(<<>>, sequence_number: @seq_no, timestamp: @rtp_ts)
  @clock_rate 90_000
  @sender_report %SenderReport{
    ssrc: 0,
    ntp_timestamp: 0xFFFF11111111FFFF,
    rtp_timestamp: 0,
    packet_count: 0,
    octet_count: 0
  }
  @recorder %ReportRecorder{
    media_ssrc: 123_456,
    sender_ssrc: 654_321,
    clock_rate: @clock_rate
  }

  test "record_report/3" do
    ts = System.monotonic_time()
    recorder = ReportRecorder.record_report(@recorder, @sender_report, ts)

    assert %ReportRecorder{
             last_sr_ntp_timestamp: 0x11111111,
             last_sr_timestamp: ^ts
           } = recorder
  end

  describe "record_packet/3" do
    test "initial packet" do
      recorder = ReportRecorder.record_packet(@recorder, @packet, @rand_ts)

      last_report_seq_no = @seq_no - 1

      assert %ReportRecorder{
               last_seq_no: {0, @seq_no},
               last_report_seq_no: {0, ^last_report_seq_no},
               last_rtp_timestamp: @rtp_ts,
               last_timestamp: @rand_ts
             } = recorder
    end

    test "subsequent packets" do
      packet1 = %Packet{@packet | sequence_number: @seq_no - 3}
      packet2 = %Packet{@packet | sequence_number: @seq_no - 2}
      packet3 = %Packet{@packet | sequence_number: @seq_no - 1}

      recorder =
        @recorder
        |> ReportRecorder.record_packet(packet1, @rand_ts)
        |> ReportRecorder.record_packet(packet3, @rand_ts)
        |> ReportRecorder.record_packet(@packet, @rand_ts)
        |> ReportRecorder.record_packet(packet2, @rand_ts)

      last_report_seq_no = @seq_no - 4

      assert %ReportRecorder{
               lost_packets: lost_packets,
               last_seq_no: {0, @seq_no},
               last_report_seq_no: {0, ^last_report_seq_no}
             } = recorder

      assert MapSet.size(lost_packets) == 0
    end

    test "missing packets" do
      packet0 = %Packet{@packet | sequence_number: @seq_no - 10}
      packet1 = %Packet{@packet | sequence_number: @seq_no - 6}
      packet2 = %Packet{@packet | sequence_number: @seq_no - 3}
      packet3 = %Packet{@packet | sequence_number: @seq_no - 1}

      recorder =
        @recorder
        |> ReportRecorder.record_packet(packet1, @rand_ts)
        # packet 0 will be ignored,
        # see comment in rtp_receiver/report_recorder.ex
        |> ReportRecorder.record_packet(packet0, @rand_ts)
        |> ReportRecorder.record_packet(packet3, @rand_ts)
        |> ReportRecorder.record_packet(@packet, @rand_ts)
        |> ReportRecorder.record_packet(packet2, @rand_ts)

      last_report_seq_no = @seq_no - 7

      assert %ReportRecorder{
               lost_packets: lost_packets,
               last_seq_no: {0, @seq_no},
               last_report_seq_no: {0, ^last_report_seq_no}
             } = recorder

      actually_lost =
        [@seq_no - 5, @seq_no - 4, @seq_no - 2]
        |> Enum.map(&{0, &1})
        |> MapSet.new()

      assert actually_lost == lost_packets
    end

    test "packets with wrapping sequence numbers" do
      max_seq_no = 65_535
      packet1 = %Packet{@packet | sequence_number: max_seq_no - 1}
      packet2 = %Packet{@packet | sequence_number: 1}
      packet3 = %Packet{@packet | sequence_number: max_seq_no}
      packet4 = %Packet{@packet | sequence_number: 0}

      recorder =
        @recorder
        |> ReportRecorder.record_packet(packet1, @rand_ts)
        |> ReportRecorder.record_packet(packet2, @rand_ts)
        |> ReportRecorder.record_packet(packet3, @rand_ts)
        |> ReportRecorder.record_packet(packet4, @rand_ts)

      sr_seq_no = {0, max_seq_no - 2}
      seq_no = {1, 1}

      assert %ReportRecorder{
               lost_packets: lost_packets,
               last_seq_no: ^seq_no,
               last_report_seq_no: ^sr_seq_no
             } = recorder

      assert MapSet.size(lost_packets) == 0
    end

    test "properly calculates jitter" do
      # 20 ms = clock_rate * (20/1000) in RTP timestamp units
      ts_diff = 20
      rtp_ts_diff = @clock_rate * (ts_diff / 1000)
      arrival_ts_diff = System.convert_time_unit(ts_diff, :millisecond, :native)

      packet = %Packet{@packet | timestamp: @rtp_ts + rtp_ts_diff}
      arrival_ts = @rand_ts + arrival_ts_diff + System.convert_time_unit(1, :millisecond, :native)

      recorder =
        @recorder
        |> ReportRecorder.record_packet(@packet, @rand_ts)
        |> ReportRecorder.record_packet(packet, arrival_ts)

      # second packet arrived 1 millisecond late
      # thus, jitter should be roughly equal to 1 millisecond / 16 in RTP ts units
      assert_in_delta recorder.jitter, @clock_rate / 1000 / 16, 0.5

      # remaining packets arrived perfectly on time
      # so the jitter should slowly converge to 0
      recorder =
        Enum.reduce(2..100, recorder, fn i, recorder ->
          packet = %Packet{@packet | timestamp: @rtp_ts + i * rtp_ts_diff}
          arrival_ts = @rand_ts + i * arrival_ts_diff
          ReportRecorder.record_packet(recorder, packet, arrival_ts)
        end)

      assert_in_delta recorder.jitter, 0, 0.5
    end
  end

  test "get_report/2" do
    end_seq_no = 65_532

    recorder =
      65_500..end_seq_no
      |> Enum.reduce(@recorder, fn i, recorder ->
        packet = %Packet{@packet | sequence_number: i}
        ReportRecorder.record_packet(recorder, packet, @rand_ts)
      end)
      |> ReportRecorder.record_report(@sender_report, @rand_ts)

    one_second = System.convert_time_unit(1, :second, :native)
    assert {:ok, report, recorder} = ReportRecorder.get_report(recorder, @rand_ts + one_second)
    assert %ReceiverReport{reports: [rec_report]} = report

    assert %ReceptionReport{
             delay: 65_536,
             last_sr: 0x11111111,
             fraction_lost: 0,
             last_sequence_number: ^end_seq_no,
             total_lost: 0
           } = rec_report

    # now let's drop some and wrap around seq_no boundary
    end_seq_no = 30

    recorder =
      Enum.reduce(0..end_seq_no//3, recorder, fn i, recorder ->
        packet = %Packet{@packet | sequence_number: i}
        ReportRecorder.record_packet(recorder, packet, @rand_ts)
      end)

    assert {:ok, report, _recorder} =
             ReportRecorder.get_report(recorder, @rand_ts + 2 * one_second)

    assert %ReceiverReport{reports: [rec_report]} = report

    lost = 23

    assert %ReceptionReport{
             delay: 131_072,
             last_sr: 0x11111111,
             fraction_lost: fraction_lost,
             last_sequence_number: last_sequence_number,
             total_lost: ^lost
           } = rec_report

    assert last_sequence_number == (1 <<< 16 ||| end_seq_no)
    assert fraction_lost == round(lost * 256 / 34)
  end
end
