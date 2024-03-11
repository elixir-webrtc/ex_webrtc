defmodule ExWebRTC.PeerConnection.TWCCRecorderTest do
  use ExUnit.Case, async: true

  alias ExRTCP.Packet.TransportFeedback.CC
  alias ExWebRTC.PeerConnection.TWCCRecorder

  @max_seq_no 0xFFFF
  @seq_no 541

  @recorder TWCCRecorder.new(1, 2)

  describe "record_packet/2" do
    test "initial case" do
      recorder = TWCCRecorder.record_packet(@recorder, @seq_no)
      end_seq_no = @seq_no + 1

      assert %TWCCRecorder{
               timestamps: %{@seq_no => _timestamp},
               base_seq_no: @seq_no,
               start_seq_no: @seq_no,
               end_seq_no: ^end_seq_no
             } = recorder
    end

    test "packets in order" do
      seq_no_2 = @seq_no + 1
      seq_no_3 = @seq_no + 2

      recorder = TWCCRecorder.record_packet(@recorder, @seq_no)
      Process.sleep(1)
      recorder = TWCCRecorder.record_packet(recorder, seq_no_2)
      Process.sleep(1)
      recorder = TWCCRecorder.record_packet(recorder, seq_no_3)
      end_seq_no = @seq_no + 3

      assert %TWCCRecorder{
               timestamps: %{
                 @seq_no => timestamp_1,
                 ^seq_no_2 => timestamp_2,
                 ^seq_no_3 => timestamp_3
               },
               base_seq_no: @seq_no,
               start_seq_no: @seq_no,
               end_seq_no: ^end_seq_no
             } = recorder

      assert timestamp_1 < timestamp_2
      assert timestamp_2 < timestamp_3
    end

    test "packets out of order, with gaps" do
      seq_no_2 = @seq_no + 5
      seq_no_3 = @seq_no + 3

      recorder = TWCCRecorder.record_packet(@recorder, @seq_no)
      Process.sleep(15)
      recorder = TWCCRecorder.record_packet(recorder, seq_no_2)
      Process.sleep(15)
      recorder = TWCCRecorder.record_packet(recorder, seq_no_3)

      end_seq_no = @seq_no + 6

      assert %TWCCRecorder{
               timestamps: %{
                 @seq_no => timestamp_1,
                 ^seq_no_2 => timestamp_2,
                 ^seq_no_3 => timestamp_3
               },
               base_seq_no: @seq_no,
               start_seq_no: @seq_no,
               end_seq_no: ^end_seq_no
             } = recorder

      assert timestamp_1 < timestamp_2
      assert timestamp_2 < timestamp_3
    end

    test "packets wrapping around sequence number boundary" do
      seq_no_1 = 65_532
      seq_no_2 = 65_533
      seq_no_3 = 65_534
      seq_no_4 = 65_535
      # following are too big to fit in 16bit
      seq_no_5 = 65_538
      seq_no_6 = 65_539
      seq_no_7 = 65_541

      recorder =
        @recorder
        |> TWCCRecorder.record_packet(seq_no_2)
        |> TWCCRecorder.record_packet(seq_no_1)
        |> TWCCRecorder.record_packet(seq_no_5 - @max_seq_no - 1)
        |> TWCCRecorder.record_packet(seq_no_4)
        |> TWCCRecorder.record_packet(seq_no_6 - @max_seq_no - 1)
        |> TWCCRecorder.record_packet(seq_no_3)
        |> TWCCRecorder.record_packet(seq_no_7 - @max_seq_no - 1)

      end_seq_no = seq_no_7 + 1

      assert %TWCCRecorder{
               timestamps: %{
                 ^seq_no_1 => _,
                 ^seq_no_2 => _,
                 ^seq_no_3 => _,
                 ^seq_no_4 => _,
                 ^seq_no_5 => _,
                 ^seq_no_6 => _,
                 ^seq_no_7 => _
               },
               base_seq_no: ^seq_no_1,
               start_seq_no: ^seq_no_1,
               end_seq_no: ^end_seq_no
             } = recorder
    end

    test "removing packets too old" do
      seq_no_2 = @seq_no + 1
      seq_no_3 = @seq_no + 3
      seq_no_4 = @seq_no + 7
      seq_no_5 = @seq_no + 11
      seq_no_6 = @seq_no + 15
      seq_no_7 = @seq_no + 16

      recorder =
        @recorder
        |> TWCCRecorder.record_packet(@seq_no)
        |> TWCCRecorder.record_packet(seq_no_2)

      end_seq_no = seq_no_2 + 1

      assert %TWCCRecorder{
               base_seq_no: @seq_no,
               start_seq_no: @seq_no,
               end_seq_no: ^end_seq_no,
               timestamps: timestamps
             } = recorder

      assert map_size(timestamps) == 2

      Process.sleep(550)

      recorder =
        recorder
        |> TWCCRecorder.record_packet(seq_no_3)
        |> TWCCRecorder.record_packet(seq_no_4)
        |> TWCCRecorder.record_packet(seq_no_5)

      start_seq_no = seq_no_2 + 1
      end_seq_no = seq_no_5 + 1

      assert %TWCCRecorder{
               base_seq_no: ^start_seq_no,
               start_seq_no: ^start_seq_no,
               end_seq_no: ^end_seq_no,
               timestamps: timestamps
             } = recorder

      assert map_size(timestamps) == 3

      Process.sleep(550)

      recorder =
        recorder
        |> TWCCRecorder.record_packet(seq_no_6)
        |> TWCCRecorder.record_packet(seq_no_7)

      start_seq_no = seq_no_5 + 1
      end_seq_no = seq_no_7 + 1

      assert %TWCCRecorder{
               base_seq_no: ^start_seq_no,
               start_seq_no: ^start_seq_no,
               end_seq_no: ^end_seq_no,
               timestamps: timestamps
             } = recorder

      assert map_size(timestamps) == 2
    end
  end

  describe "get_feedback/1" do
    test "subsequent packets in order" do
      base_ts = 1_300

      timestamps = %{
        @seq_no => base_ts,
        (@seq_no + 1) => base_ts,
        (@seq_no + 2) => base_ts + 20,
        (@seq_no + 3) => base_ts + 32
      }

      recorder = %TWCCRecorder{
        @recorder
        | base_seq_no: @seq_no,
          start_seq_no: @seq_no,
          end_seq_no: @seq_no + 4,
          timestamps: timestamps
      }

      assert {[feedback], recorder} = TWCCRecorder.get_feedback(recorder)

      assert %CC{
               base_sequence_number: @seq_no,
               reference_time: 5,
               fb_pkt_count: 0,
               packet_status_count: 4,
               packet_chunks: [%CC.RunLength{status_symbol: :small_delta, run_length: 4}],
               recv_deltas: [20, 0, 20, 12]
             } = feedback

      # no new packets -> no feedback
      assert {[], _recorder} = TWCCRecorder.get_feedback(recorder)
    end

    test "packets out of order, with gaps" do
      base_ts = 1_250

      timestamps = %{
        @seq_no => base_ts + 20,
        (@seq_no + 1) => base_ts + 25,
        (@seq_no + 2) => base_ts + 8,
        (@seq_no + 3) => base_ts,
        (@seq_no + 5) => base_ts + 25
      }

      recorder = %TWCCRecorder{
        @recorder
        | base_seq_no: @seq_no,
          start_seq_no: @seq_no,
          end_seq_no: @seq_no + 6,
          timestamps: timestamps
      }

      assert {[feedback], recorder} = TWCCRecorder.get_feedback(recorder)

      symbols = [
        :small_delta,
        :small_delta,
        :large_delta,
        :large_delta,
        :not_received,
        :small_delta,
        :not_received
      ]

      assert %CC{
               base_sequence_number: @seq_no,
               reference_time: 4,
               fb_pkt_count: 0,
               packet_status_count: 6,
               packet_chunks: [%CC.StatusVector{symbols: ^symbols}],
               recv_deltas: [246, 5, -17, -8, 25]
             } = feedback

      assert {[], _recorder} = TWCCRecorder.get_feedback(recorder)
    end

    test "mixed chunks" do
      end_no = 634
      packet_num = end_no - @seq_no + 1

      recorder = TWCCRecorder.record_packet(@recorder, @seq_no)

      recorder =
        Enum.reduce((@seq_no + 2)..end_no, recorder, fn i, recorder ->
          TWCCRecorder.record_packet(recorder, i)
        end)

      assert {[feedback], recorder} = TWCCRecorder.get_feedback(recorder)

      assert %CC{
               base_sequence_number: @seq_no,
               fb_pkt_count: 0,
               packet_status_count: ^packet_num,
               packet_chunks: [chunk1, chunk2],
               recv_deltas: deltas
             } = feedback

      symbols = [:small_delta, :not_received] ++ List.duplicate(:small_delta, 12)
      assert %CC.StatusVector{symbols: ^symbols} = chunk1

      run_length = packet_num - 14

      assert %CC.RunLength{
               status_symbol: :small_delta,
               run_length: ^run_length
             } = chunk2

      assert length(deltas) == packet_num - 1

      assert {[], _recorder} = TWCCRecorder.get_feedback(recorder)
    end

    test "split into two feedbacks" do
      recorder =
        @recorder
        |> TWCCRecorder.record_packet(@seq_no)
        |> TWCCRecorder.record_packet(@seq_no + 1)
        |> TWCCRecorder.record_packet(@seq_no + 2)

      # simulate huge delta between 3rd and 4th packet
      base_no2 = @seq_no + 2
      timestamps = Map.update!(recorder.timestamps, base_no2, &(&1 + 35_000))
      recorder = %{recorder | timestamps: timestamps}

      assert {[feedback1, feedback2], recorder} = TWCCRecorder.get_feedback(recorder)

      assert %CC{
               base_sequence_number: @seq_no,
               fb_pkt_count: 0,
               packet_status_count: 2,
               reference_time: ref_time1,
               packet_chunks: [%CC.RunLength{status_symbol: :small_delta, run_length: 2}],
               recv_deltas: [_d1, _d2]
             } = feedback1

      assert %CC{
               base_sequence_number: ^base_no2,
               fb_pkt_count: 1,
               packet_status_count: 1,
               reference_time: ref_time2,
               packet_chunks: [%CC.RunLength{status_symbol: :small_delta, run_length: 1}],
               recv_deltas: [_d3]
             } = feedback2

      # ref times should differ by about 136 * 64 ms
      refute_in_delta ref_time1, ref_time2, 133
      assert_in_delta ref_time1, ref_time2, 143

      assert {[], _recorder} = TWCCRecorder.get_feedback(recorder)
    end
  end
end
