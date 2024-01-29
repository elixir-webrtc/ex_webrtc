defmodule ExWebRTC.PeerConnection.TWCCRecorderTest do
  use ExUnit.Case, async: true

  alias ExWebRTC.PeerConnection.TWCCRecorder

  @max_seq_no 0xFFFF
  @seq_no 541

  @recorder %TWCCRecorder{sender_ssrc: 1, media_ssrc: 2}

  describe "record_packet/2" do
    test "initial case" do
      recorder =
        @recorder
        |> TWCCRecorder.record_packet(@seq_no)

      end_seq_no = @seq_no + 1

      assert %{
               timestamps: %{@seq_no => _timestamp},
               base_seq_no: @seq_no,
               start_seq_no: @seq_no,
               end_seq_no: ^end_seq_no
             } = recorder
    end

    test "packets in order" do
      seq_no_2 = @seq_no + 1
      seq_no_3 = @seq_no + 2

      recorder =
        @recorder
        |> TWCCRecorder.record_packet(@seq_no)

      Process.sleep(15)
      recorder = TWCCRecorder.record_packet(recorder, seq_no_2)
      Process.sleep(15)
      recorder = TWCCRecorder.record_packet(recorder, seq_no_3)

      end_seq_no = @seq_no + 3

      assert %{
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

      recorder =
        @recorder
        |> TWCCRecorder.record_packet(@seq_no)

      Process.sleep(15)
      recorder = TWCCRecorder.record_packet(recorder, seq_no_2)
      Process.sleep(15)
      recorder = TWCCRecorder.record_packet(recorder, seq_no_3)

      end_seq_no = @seq_no + 6

      assert %{
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

      assert %{
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

      assert %{
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

      assert %{
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

      assert %{
               base_seq_no: ^start_seq_no,
               start_seq_no: ^start_seq_no,
               end_seq_no: ^end_seq_no,
               timestamps: timestamps
             } = recorder

      assert map_size(timestamps) == 2
    end
  end

  describe "get_feedback/1" do
    test "" do
    end
  end
end
