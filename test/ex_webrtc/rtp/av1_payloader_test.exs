defmodule ExWebRTC.RTP.AV1PayloaderTest do
  use ExUnit.Case, async: true

  alias ExWebRTC.Media.IVFReader
  alias ExWebRTC.RTP.AV1Payloader

  @tag :debug
  test "payload av1 video" do
    # video frames in the fixture are mostly 500+ bytes
    av1_payloader = AV1Payloader.new(200)
    {:ok, ivf_reader} = IVFReader.open("test/fixtures/ivf/av1_correct.ivf")
    {:ok, _header} = IVFReader.read_header(ivf_reader)

    for _i <- 0..28, reduce: av1_payloader do
      av1_payloader ->
        {:ok, frame} = IVFReader.next_frame(ivf_reader)
        {rtp_packets, av1_payloader} = AV1Payloader.payload(av1_payloader, frame.data)

        # assert all packets but last are 200 bytes
        # rtp_packets
        # |> Enum.slice(0, length(rtp_packets) - 1)
        # |> Enum.each(fn rtp_packet ->
        #   assert byte_size(rtp_packet.payload) == 200
        # end)

        # last_rtp = List.last(rtp_packets)
        # assert byte_size(last_rtp.payload) < 200
        # assert last_rtp.marker == true

        av1_payloader
    end
  end
end
