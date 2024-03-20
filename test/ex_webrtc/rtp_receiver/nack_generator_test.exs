defmodule ExWebRTC.RTPReceiver.NACKGeneratorTest do
  use ExUnit.Case, async: true

  alias ExWebRTC.RTPReceiver.NACKGenerator
  alias ExRTCP.Packet.TransportFeedback.NACK

  @generator %NACKGenerator{}
  @packet ExRTP.Packet.new(<<>>)

  describe "record_packet/2" do
    test "subsequent packets" do
      generator =
        @generator
        |> NACKGenerator.record_packet(%{@packet | sequence_number: 115})
        |> NACKGenerator.record_packet(%{@packet | sequence_number: 120})

      assert %NACKGenerator{
               lost_packets: lost_packets,
               last_sn: 120
             } = generator

      assert Map.keys(lost_packets) == Enum.to_list(116..119)

      generator =
        Enum.reduce(113..117, generator, fn sn, generator ->
          NACKGenerator.record_packet(generator, %{@packet | sequence_number: sn})
        end)

      assert %NACKGenerator{
               lost_packets: lost_packets,
               last_sn: 120
             } = generator

      assert Map.keys(lost_packets) == [118, 119]

      generator =
        Enum.reduce(116..122, generator, fn sn, generator ->
          NACKGenerator.record_packet(generator, %{@packet | sequence_number: sn})
        end)

      assert %NACKGenerator{
               lost_packets: %{},
               last_sn: 122
             } = generator
    end

    test "subsequent packets wrapping, out of order" do
      generator =
        @generator
        |> NACKGenerator.record_packet(%{@packet | sequence_number: 0xFFFE})
        |> NACKGenerator.record_packet(%{@packet | sequence_number: 1})

      assert %NACKGenerator{
               lost_packets: lost_packets,
               last_sn: 1
             } = generator

      assert Map.keys(lost_packets) == [0, 0xFFFF]

      generator =
        generator
        |> NACKGenerator.record_packet(%{@packet | sequence_number: 0})
        |> NACKGenerator.record_packet(%{@packet | sequence_number: 0xFFFF})

      assert %NACKGenerator{
               lost_packets: %{},
               last_sn: 1
             } = generator
    end
  end

  describe "get_feedback/1" do
    test "with no missing packets" do
      generator = NACKGenerator.record_packet(@generator, @packet)

      {feedback, ^generator} = NACKGenerator.get_feedback(generator)
      assert feedback == nil
    end

    test "with missing packets" do
      generator =
        %{@generator | max_nack: 2}
        |> NACKGenerator.record_packet(%{@packet | sequence_number: 554})
        |> NACKGenerator.record_packet(%{@packet | sequence_number: 558})
        |> NACKGenerator.record_packet(%{@packet | sequence_number: 556})
        |> NACKGenerator.record_packet(%{@packet | sequence_number: 559})

      {feedback, generator} = NACKGenerator.get_feedback(generator)

      assert %NACK{nacks: [nack]} = feedback
      assert %{pid: 555, blp: <<0::14, 1::1, 0::1>>} = nack
      assert %{555 => 1, 557 => 1} == generator.lost_packets

      generator = NACKGenerator.record_packet(generator, %{@packet | sequence_number: 561})

      assert %{555 => 1, 557 => 1, 560 => 2} = generator.lost_packets

      {feedback, generator} = NACKGenerator.get_feedback(generator)

      assert %NACK{nacks: [nack]} = feedback
      assert %{pid: 555, blp: <<0::11, 1::1, 0::2, 1::1, 0::1>>} = nack
      assert %{560 => 1} == generator.lost_packets

      {feedback, _generator} = NACKGenerator.get_feedback(generator)
      assert %NACK{nacks: [nack]} = feedback
      assert %{pid: 560, blp: <<0::16>>} = nack
    end
  end
end
