defmodule ExWebRTC.RTP.AV1.PayloaderTest do
  use ExUnit.Case, async: true

  alias ExWebRTC.Media.IVF.Reader
  alias ExWebRTC.RTP.Payloader

  test "payload av1 video" do
    # some OBUs in the fixture are bigger than 101 bytes
    av1_payloader = Payloader.AV1.new(101)
    {:ok, _header, ivf_reader} = Reader.open("test/fixtures/ivf/av1_correct.ivf")

    for _i <- 0..28, reduce: av1_payloader do
      av1_payloader ->
        {:ok, frame} = Reader.next_frame(ivf_reader)
        {rtp_packets, av1_payloader} = Payloader.AV1.payload(av1_payloader, frame.data)

        # assert all packets are no bigger than 101 bytes
        rtp_packets
        |> Enum.each(fn rtp_packet ->
          assert byte_size(rtp_packet.payload) <= 101
        end)

        last_rtp = List.last(rtp_packets)
        assert last_rtp.marker == true

        av1_payloader
    end
  end
end
