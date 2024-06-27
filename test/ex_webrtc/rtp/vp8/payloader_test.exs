defmodule ExWebRTC.RTP.VP8.PayloaderTest do
  use ExUnit.Case, async: true

  alias ExWebRTC.Media.IVF.Reader
  alias ExWebRTC.RTP.VP8.Payloader

  test "payload vp8 video" do
    # video frames in the fixture are mostly 500+ bytes
    vp8_payloader = Payloader.new(200)
    {:ok, _header, ivf_reader} = Reader.open("test/fixtures/ivf/vp8_correct.ivf")

    for _i <- 0..28, reduce: vp8_payloader do
      vp8_payloader ->
        {:ok, frame} = Reader.next_frame(ivf_reader)
        {rtp_packets, vp8_payloader} = Payloader.payload(vp8_payloader, frame.data)

        # assert all packets but last are 200 bytes
        rtp_packets
        |> Enum.slice(0, length(rtp_packets) - 1)
        |> Enum.each(fn rtp_packet ->
          assert byte_size(rtp_packet.payload) == 200
        end)

        last_rtp = List.last(rtp_packets)
        assert byte_size(last_rtp.payload) < 200
        assert last_rtp.marker == true

        vp8_payloader
    end
  end
end
