defmodule ExWebRTC.RTPReceiver.NACKResponderTest do
  use ExUnit.Case, async: true

  alias ExWebRTC.RTPSender.NACKResponder
  alias ExRTCP.Packet.TransportFeedback.NACK

  @responder %NACKResponder{}
  @media_ssrc 123_321
  @sender_ssrc 234_111
  @payload <<1, 2, 3, 4>>
  @packet ExRTP.Packet.new(@payload, ssrc: @media_ssrc)

  test "new/1" do
    assert %NACKResponder{size: 1024, packets: %{}} = NACKResponder.new()
    assert %NACKResponder{size: 64} = NACKResponder.new(64)

    # initial RTX sequence number is drawn at runtime, not once at compile time
    seq_nos = for _ <- 1..20, uniq: true, do: NACKResponder.new().seq_no
    assert length(seq_nos) > 1
    assert Enum.all?(seq_nos, &(&1 in 0..0xFFFF))
  end

  test "record_packet/2" do
    packet = %{@packet | sequence_number: 234}
    nack_responder = NACKResponder.record_packet(@responder, packet)
    assert [^packet] = Map.values(nack_responder.packets)

    # a packet that is `size` sequence numbers newer takes its slot
    newer = %{@packet | sequence_number: 234 + 1024}
    nack_responder = NACKResponder.record_packet(nack_responder, newer)
    assert [^newer] = Map.values(nack_responder.packets)
  end

  test "keeps 1024 packets by default" do
    nack_responder =
      Enum.reduce(0..1023, NACKResponder.new(), fn seq_no, responder ->
        NACKResponder.record_packet(responder, %{@packet | sequence_number: seq_no})
      end)

    nack = NACK.from_sequence_numbers(@sender_ssrc, @media_ssrc, [0])

    assert {[%ExRTP.Packet{payload: <<0::16, @payload::binary>>}], _responder} =
             NACKResponder.get_rtx(nack_responder, nack)
  end

  test "keeps only the last `size` packets" do
    nack_responder =
      Enum.reduce(0..9, NACKResponder.new(4), fn seq_no, responder ->
        NACKResponder.record_packet(responder, %{@packet | sequence_number: seq_no})
      end)

    nack = NACK.from_sequence_numbers(@sender_ssrc, @media_ssrc, Enum.to_list(0..9))
    {rtx_packets, _nack_responder} = NACKResponder.get_rtx(nack_responder, nack)

    assert [6, 7, 8, 9] ==
             Enum.map(rtx_packets, fn %{payload: <<seq_no::16, _rest::binary>>} -> seq_no end)
  end

  test "get_rtx/2" do
    nack_responder =
      %NACKResponder{@responder | seq_no: 1000}
      |> NACKResponder.record_packet(%{@packet | sequence_number: 37})
      |> NACKResponder.record_packet(%{@packet | sequence_number: 38})
      |> NACKResponder.record_packet(%{@packet | sequence_number: 39})
      |> NACKResponder.record_packet(%{@packet | sequence_number: 40})

    nack = NACK.from_sequence_numbers(@sender_ssrc, @media_ssrc, [38, 39, 37 + 1024])
    {rtx_packets, nack_responder} = NACKResponder.get_rtx(nack_responder, nack)

    assert nack_responder.seq_no == 1002

    assert [
             %ExRTP.Packet{sequence_number: 1000, payload: <<38::16, @payload::binary>>},
             %ExRTP.Packet{sequence_number: 1001, payload: <<39::16, @payload::binary>>}
           ] = rtx_packets
  end

  test "get_rtx/2 wraps RTX sequence numbers" do
    nack_responder =
      %NACKResponder{@responder | seq_no: 0xFFFF}
      |> NACKResponder.record_packet(%{@packet | sequence_number: 10})
      |> NACKResponder.record_packet(%{@packet | sequence_number: 11})

    nack = NACK.from_sequence_numbers(@sender_ssrc, @media_ssrc, [10, 11])
    {rtx_packets, nack_responder} = NACKResponder.get_rtx(nack_responder, nack)

    assert [65_535, 0] == Enum.map(rtx_packets, & &1.sequence_number)
    assert nack_responder.seq_no == 1
  end
end
